#!/usr/bin/env python3
"""Burst load generator for the pastebin API (stdlib-only, no deps).

Purpose: hammer the box with escalating bursts and see whether it CRASHES or
sheds load gracefully. The new rate-limiting design is supposed to shed, not die:
  - global concurrency cap  -> excess requests get 503 + Retry-After
  - cache-as-limiter        -> creates that outrun the persister get 429 + Retry-After
So 503/429 are HEALTHY outcomes here; transport errors (refused/reset/timeout) and
5xx-other are DISTRESS signals that suggest the box is falling over.

Runs a ramp of stages at increasing concurrency. After each stage it fires a
single health probe; two consecutive failed probes abort the ramp (box is down).

Usage:
  burst_test.py --url http://100.120.214.111 --scenario read \
      --ramp 5:5,20:10,50:10,100:10,200:15,400:15
  burst_test.py --url http://100.120.214.111 --scenario write \
      --ramp 10:8,30:10,60:10 --write-size 200000 --admin-token XXXX
"""
import argparse, json, socket, ssl, sys, time, threading
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from http.client import HTTPConnection, HTTPSConnection
from urllib.parse import urlsplit

# --- a single request outcome ------------------------------------------------
class R:
    __slots__ = ("status", "err", "lat", "nbytes", "body", "retry_after")
    def __init__(self, status=None, err=None, lat=0.0, nbytes=0, body=None, retry_after=None):
        self.status = status; self.err = err; self.lat = lat
        self.nbytes = nbytes; self.body = body; self.retry_after = retry_after

_TLS = ssl.create_default_context()

def do_request(host, port, tls, method, path, body, headers, timeout, capture_body):
    t0 = time.perf_counter()
    conn = None
    try:
        conn = (HTTPSConnection(host, port, timeout=timeout, context=_TLS) if tls
                else HTTPConnection(host, port, timeout=timeout))
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        data = resp.read()
        return R(status=resp.status, lat=time.perf_counter() - t0, nbytes=len(data),
                 body=data if capture_body else None, retry_after=resp.getheader("Retry-After"))
    except (socket.timeout, TimeoutError):
        return R(err="timeout", lat=time.perf_counter() - t0)
    except ConnectionRefusedError:
        return R(err="refused", lat=time.perf_counter() - t0)
    except ConnectionResetError:
        return R(err="reset", lat=time.perf_counter() - t0)
    except (BrokenPipeError, socket.gaierror) as e:
        return R(err=type(e).__name__, lat=time.perf_counter() - t0)
    except OSError as e:
        return R(err="oserr:%s" % (e.errno,), lat=time.perf_counter() - t0)
    except Exception as e:
        return R(err="err:%s" % (type(e).__name__,), lat=time.perf_counter() - t0)
    finally:
        if conn is not None:
            try: conn.close()
            except Exception: pass

# --- one stage: N workers loop until the deadline ----------------------------
def run_stage(target, concurrency, seconds, max_requests, make_req):
    host, port, tls = target
    deadline = time.perf_counter() + seconds
    results = []
    lock = threading.Lock()
    budget = [max_requests]  # shared request cap across workers (safety)

    def worker():
        local = []
        while time.perf_counter() < deadline:
            with lock:
                if budget[0] <= 0:
                    break
                budget[0] -= 1
            method, path, body, headers, cap = make_req()
            local.append(do_request(host, port, tls, method, path, body, headers, 15.0, cap))
        with lock:
            results.extend(local)

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as ex:
        for _ in range(concurrency):
            ex.submit(worker)
    wall = time.perf_counter() - t0
    return results, wall

# --- summarise a stage -------------------------------------------------------
def pct(sorted_vals, p):
    if not sorted_vals: return 0.0
    i = min(len(sorted_vals) - 1, int(round(p / 100.0 * (len(sorted_vals) - 1))))
    return sorted_vals[i]

def summarize(results, wall):
    n = len(results)
    codes = Counter()
    errs = Counter()
    lats_ok = []
    for r in results:
        if r.err:
            errs[r.err] += 1
            codes["ERR"] += 1
        else:
            codes[r.status] += 1
            lats_ok.append(r.lat)
    lats_ok.sort()
    ok = sum(v for k, v in codes.items() if isinstance(k, int) and 200 <= k < 300)
    notfound = codes.get(404, 0)
    shed503 = codes.get(503, 0)
    shed429 = codes.get(429, 0)
    server_err = sum(v for k, v in codes.items()
                     if isinstance(k, int) and 500 <= k < 600 and k != 503)
    transport = codes.get("ERR", 0)
    return {
        "n": n, "wall": wall, "rps": (n / wall if wall else 0.0),
        "ok2xx": ok, "notfound404": notfound, "shed503": shed503, "shed429": shed429,
        "server_err_5xx": server_err, "transport_err": transport,
        "codes": dict(codes), "errs": dict(errs),
        "lat_ms": {
            "p50": pct(lats_ok, 50) * 1000, "p90": pct(lats_ok, 90) * 1000,
            "p99": pct(lats_ok, 99) * 1000,
            "max": (lats_ok[-1] * 1000 if lats_ok else 0.0),
        },
    }

def health_probe(target, path="/"):
    host, port, tls = target
    r = do_request(host, port, tls, "GET", path, None, {}, 8.0, False)
    return (r.err is None and r.status is not None and r.status < 500), (r.status or r.err)

# --- request builders per scenario -------------------------------------------
def make_builders(scenario, sizes):
    read_paths = ["/api/pastes", "/"]
    idx = [0]
    def read_req():
        p = read_paths[idx[0] % len(read_paths)]; idx[0] += 1
        return ("GET", p, None, {"Accept": "application/json"}, False)
    # precompute one JSON body per configured size; write_req cycles through them
    # so a single run can mix big and small pastes (e.g. --sizes 500,200000).
    bodies = [json.dumps({"content": "x" * s, "title": "BURSTTEST"}).encode() for s in sizes]
    wi = [0]
    def write_req():
        body = bodies[wi[0] % len(bodies)]; wi[0] += 1
        return ("POST", "/api/pastes", body,
                {"Content-Type": "application/json"}, True)
    mix = [0]
    def mixed_req():
        mix[0] += 1
        return write_req() if mix[0] % 4 == 0 else read_req()
    return {"read": read_req, "write": write_req, "mixed": mixed_req}[scenario]

# --- concurrent liveness monitor: is the box reachable DURING the burst? -----
class Liveness(threading.Thread):
    """Probes a cheap endpoint on a fixed cadence for the whole run, so we can
    report real uptime% while the burst is hammering the create path."""
    def __init__(self, target, path, interval):
        super().__init__(daemon=True)
        self.target = target; self.path = path; self.interval = interval
        self._stop = threading.Event()
        self.samples = []  # (ok: bool, status_or_err)
    def run(self):
        host, port, tls = self.target
        while not self._stop.is_set():
            r = do_request(host, port, tls, "GET", self.path, None, {}, 3.0, False)
            ok = (r.err is None and r.status is not None and r.status < 500)
            self.samples.append((ok, r.status if r.err is None else r.err))
            self._stop.wait(self.interval)
    def stop(self): self._stop.set()
    def report(self):
        n = len(self.samples)
        if not n: return "no liveness samples"
        ok = sum(1 for s in self.samples if s[0])
        # longest consecutive run of failed probes (worst continuous downtime)
        worst = cur = 0
        for s in self.samples:
            cur = 0 if s[0] else cur + 1
            worst = max(worst, cur)
        bad = Counter(s[1] for s in self.samples if not s[0])
        return ("uptime=%.1f%% (%d/%d probes ok, cadence=%.1fs)  "
                "worst_continuous_downtime=%.1fs  fail_reasons=%s"
                % (100.0 * ok / n, ok, n, self.interval, worst * self.interval, dict(bad)))

def harvest_ids(results, created_ids):
    for r in results:
        if r.body and r.status == 200:
            try:
                pid = json.loads(r.body).get("id")
                if pid: created_ids.append(pid)
            except Exception: pass

def cleanup(target, admin_token, created_ids):
    host, port, tls = target
    ok = 0; fail = 0
    for pid in created_ids:
        r = do_request(host, port, tls, "DELETE", "/api/admin/pastes/%s" % pid,
                       None, {"X-Admin-Token": admin_token}, 10.0, False)
        if r.err is None and r.status == 200: ok += 1
        else: fail += 1
    return ok, fail

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True, help="base url, e.g. http://100.120.214.111")
    ap.add_argument("--scenario", choices=["read", "write", "mixed"], default="read")
    ap.add_argument("--ramp", default="5:5,20:10,50:10,100:10,200:15,400:15",
                    help="comma list of concurrency:seconds stages")
    ap.add_argument("--max-requests", type=int, default=200000,
                    help="hard per-stage request cap (safety)")
    ap.add_argument("--write-size", type=int, default=500, help="bytes of paste content for writes")
    ap.add_argument("--sizes", default="", help="comma list of write byte-sizes to cycle (e.g. 500,200000); overrides --write-size")
    ap.add_argument("--admin-token", default="", help="if set, delete created pastes at the end")
    ap.add_argument("--ids-file", default="", help="write every created paste id here (for cleanup)")
    ap.add_argument("--liveness-path", default="/", help="endpoint probed continuously for uptime%%")
    ap.add_argument("--liveness-interval", type=float, default=0.5, help="seconds between liveness probes")
    ap.add_argument("--no-health-abort", action="store_true")
    args = ap.parse_args()
    sizes = [int(x) for x in args.sizes.split(",")] if args.sizes else [args.write_size]

    u = urlsplit(args.url)
    tls = (u.scheme == "https")
    port = u.port or (443 if tls else 80)
    target = (u.hostname, port, tls)

    stages = []
    for tok in args.ramp.split(","):
        c, s = tok.split(":"); stages.append((int(c), float(s)))

    created_ids = []
    make_req = make_builders(args.scenario, sizes)

    print("== burst_test ==")
    print("target=%s scenario=%s tls=%s sizes=%s" % (args.url, args.scenario, tls, sizes))
    print("ramp=%s" % (args.ramp,))
    ok0, st0 = health_probe(target)
    print("pre-flight health: %s (%s)" % ("UP" if ok0 else "DOWN", st0))
    if not ok0:
        print("!! target not healthy before test; aborting"); sys.exit(2)

    # Liveness: probe a REAL paste read (nginx->api->cache/DB) throughout the burst,
    # so uptime% reflects whether the backend keeps serving, not just nginx static.
    host, port, tls_ = target
    live_path = args.liveness_path
    if live_path == "/":
        cr = do_request(host, port, tls_, "POST", "/api/pastes",
                        json.dumps({"content": "canary", "title": "BURSTTEST-CANARY"}).encode(),
                        {"Content-Type": "application/json"}, 10.0, True)
        cid = None
        try:
            cid = json.loads(cr.body).get("id") if cr.body else None
        except Exception:
            cid = None
        if cid:
            created_ids.append(cid)
            live_path = "/api/pastes/%s" % cid
            print("liveness: probing real paste read %s every %.1fs" % (live_path, args.liveness_interval))
        else:
            print("WARN: canary paste create failed; liveness falls back to GET /")
    liveness = Liveness(target, live_path, args.liveness_interval)
    liveness.start()

    fails = 0
    verdict = "SURVIVED"
    for (c, s) in stages:
        results, wall = run_stage(target, c, s, args.max_requests, make_req)
        if args.scenario in ("write", "mixed"):
            harvest_ids(results, created_ids)
        summ = summarize(results, wall)
        print("\n-- stage conc=%d for %.0fs --" % (c, s))
        print("  requests=%d wall=%.1fs rps=%.0f" % (summ["n"], summ["wall"], summ["rps"]))
        print("  ok2xx=%d 404=%d  |shed| 503=%d 429=%d  |bad| 5xx=%d transport=%d"
              % (summ["ok2xx"], summ["notfound404"], summ["shed503"], summ["shed429"],
                 summ["server_err_5xx"], summ["transport_err"]))
        print("  lat_ms p50=%.0f p90=%.0f p99=%.0f max=%.0f"
              % (summ["lat_ms"]["p50"], summ["lat_ms"]["p90"],
                 summ["lat_ms"]["p99"], summ["lat_ms"]["max"]))
        if summ["errs"]: print("  errs=%s" % (summ["errs"],))
        if summ["server_err_5xx"] or summ["transport_err"]:
            print("  ^^ DISTRESS signals present")
        up, st = health_probe(target)
        print("  post-stage health: %s (%s)" % ("UP" if up else "DOWN", st))
        if not up:
            fails += 1
            if fails >= 2 and not args.no_health_abort:
                verdict = "CRASHED (health probe failed twice)"
                break
        else:
            fails = 0

    liveness.stop(); liveness.join(timeout=2)
    live = liveness.report()
    print("\n== LIVENESS (during burst): %s ==" % live)
    # A real crash/unresponsiveness = the box stopped answering a trivial read.
    if "uptime=100.0%" not in live and verdict == "SURVIVED":
        verdict = "SURVIVED-BUT-DEGRADED (backend not 100%% reachable during burst)"

    print("\n== VERDICT: %s ==" % verdict)
    if args.ids_file and created_ids:
        with open(args.ids_file, "w") as fh:
            fh.write("\n".join(created_ids) + "\n")
        print("wrote %d created ids -> %s" % (len(created_ids), args.ids_file))
    if args.admin_token and created_ids:
        print("cleaning up %d created pastes ..." % len(created_ids))
        cok, cfail = cleanup(target, args.admin_token, created_ids)
        print("  deleted=%d failed=%d" % (cok, cfail))
    elif created_ids:
        print("NOTE: created %d pastes (titled BURSTTEST) NOT cleaned up "
              "(no --admin-token). ids sample: %s" % (len(created_ids), created_ids[:5]))
    sys.exit(0 if verdict == "SURVIVED" else 1)

if __name__ == "__main__":
    main()
