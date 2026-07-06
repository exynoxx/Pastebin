## Per-IP abuse protection: request rate limiting + overload protection, and the paste-creation
## burst/penalty guard — unified onto one lock, one per-IP table, and one idle-entry sweep.
##
## Two policies, two entry points, kept distinct because they enforce different things:
##
## 1. `tryAcquire` — runs on EVERY request (via the `rateLimit` middleware below, composed in
##    endpoints/dispatch.nim), mirroring the chained
##    limiters in pastebin-api/program.cs. Three limiters apply, in order:
##      a. per-IP sliding window   (perIpPerMinute,  1 min, 6 segments)
##      b. global sliding window   (globalPerMinute, 1 min, 6 segments)
##      c. global concurrency cap  (globalConcurrency, no queue)
##    plus a stricter per-IP fixed-window "uploads" policy on the two upload routes. Any rejection
##    -> the route layer answers 503 + Retry-After: 10. On success the caller MUST release the
##    concurrency slot when the request finishes.
##
## 2. `checkPasteCreate` — runs only when creating a paste, mirroring
##    pastebin-api/services/PasteRateGuard.cs. Normal mode: up to burstLimit pastes within a rolling
##    windowSeconds; the paste that would exceed that is rejected AND trips a penalty box — for the
##    next penaltySeconds the IP is limited to one paste per penaltyIntervalSeconds. Rejection ->
##    the route layer answers 429 + Retry-After (via `rejectPasteLimit` below).
##
## Admin brute-force protection is deliberately NOT here — it counts failures, not requests, and
## escalates its own lockout; see endpoints/admin/guard.nim.
##
## Under Nim's shared-heap ORC the state Table is reachable from all worker threads, so a single
## process-wide lock guards every access.
##
## This module also owns how the two policies surface over HTTP: `rateLimit` (the request middleware
## that answers 503) and `rejectPasteLimit` (the paste 429). Keeping the decision logic and its
## HTTP presentation together is why this module depends on the framework.

import std/[tables, deques, locks, times, json]
import config
import webframework/[httpserver, context, middleware]

const
    Segments = 6
    WindowSec = 60
    SegLenSec = WindowSec div Segments   # 10s

type
    SlidingState = ref object
        counts: array[Segments, int]
        lastSeg: int64
    FixedState = ref object
        windowStart: int64
        count: int

    IpState = ref object
        req: SlidingState     ## per-IP request sliding window (tryAcquire)
        up: FixedState        ## per-IP uploads fixed window (tryAcquire, upload routes)
        recent: Deque[int64]  ## unix-second timestamps of allowed pastes in the burst window
        penaltyUntil: int64   ## unix second the paste penalty ends (0 = not penalized)
        lastAllowed: int64    ## unix second of the most recent allowed paste
        lastSeen: int64       ## unix second of the last touch (for stale pruning)

var
    gLock: Lock
    gIps: Table[string, IpState]
    gGlobal: SlidingState
    gConcurrent: int
    gPerIpLimit, gGlobalLimit, gConcurrencyLimit, gUploadsLimit: int
    gPasteBurstLimit, gPasteWindowSeconds, gPastePenaltySeconds, gPastePenaltyIntervalSeconds: int
    gLastSweep: int64

proc initRateLimiter*(cfg: AppConfig) =
    initLock(gLock)
    gIps = initTable[string, IpState]()
    gGlobal = SlidingState(lastSeg: 0)
    gConcurrent = 0
    gPerIpLimit       = cfg.perIpPerMinute
    gGlobalLimit      = cfg.globalPerMinute
    gConcurrencyLimit = cfg.globalConcurrency
    gUploadsLimit     = cfg.uploadsPerMinute
    gPasteBurstLimit             = max(1, cfg.pasteBurstLimit)
    gPasteWindowSeconds          = max(1, cfg.pasteBurstWindowSec)
    gPastePenaltySeconds         = max(0, cfg.pastePenaltySec)
    gPastePenaltyIntervalSeconds = max(1, cfg.pastePenaltyIntervalSec)

proc slidingTry(st: SlidingState, nowSec, limit: int64): bool =
    ## Segmented sliding-window counter. Caller holds gLock.
    let seg = nowSec div SegLenSec
    if seg != st.lastSeg:
        let diff = seg - st.lastSeg
        if diff >= Segments:
            for i in 0 ..< Segments: st.counts[i] = 0
        else:
            # Clear the segments that have just rotated into the window.
            for d in 1 .. diff:
                st.counts[int((st.lastSeg + d) mod Segments)] = 0
        st.lastSeg = seg
    var total = 0
    for c in st.counts: total += c
    if total.int64 >= limit: return false
    st.counts[int(seg mod Segments)].inc
    true

proc fixedTry(st: FixedState, nowSec, limit: int64): bool =
    let winStart = (nowSec div WindowSec) * WindowSec
    if st.windowStart != winStart:
        st.windowStart = winStart
        st.count = 0
    if st.count.int64 >= limit: return false
    st.count.inc
    true

proc maybeSweep(nowSec: int64) =
    ## Drop idle per-IP entries so the table can't grow unbounded; runs at most once per window.
    ## Keeps an IP while its paste penalty is active OR it has been seen recently by either policy.
    ## Caller holds gLock.
    if nowSec - gLastSweep < WindowSec: return
    gLastSweep = nowSec
    let idleCutoff = max(WindowSec * 2, max(gPasteWindowSeconds, gPastePenaltySeconds)).int64
    var stale: seq[string]
    for ip, st in gIps:
        if nowSec >= st.penaltyUntil and nowSec - st.lastSeen > idleCutoff:
            stale.add ip
    for ip in stale: gIps.del ip

proc ipState(ip: string, nowSec: int64): IpState =
    ## Fetch (or create) the per-IP state and stamp lastSeen. Caller holds gLock.
    if ip notin gIps:
        gIps[ip] = IpState(
            req: SlidingState(lastSeg: nowSec div SegLenSec),
            up: FixedState(),
            recent: initDeque[int64]())
    result = gIps[ip]
    result.lastSeen = nowSec

template withIpState(ip: string; nowSec, st, body: untyped) =
    ## The shared preamble of every per-IP policy check: take the process lock, sweep idle entries,
    ## and fetch this IP's state. Injects `nowSec` (current unix second) and `st` (its IpState) into
    ## `body`, and releases the lock on any exit (including `return`).
    let nowSec = getTime().toUnix()
    withLock gLock:
        maybeSweep(nowSec)
        let st = ipState(ip, nowSec)
        body

# ---- request rate limiting + overload protection ---------------------------

type AcquireResult* = object
    allowed*: bool
    concurrencyHeld*: bool

const Rejected = AcquireResult(allowed: false, concurrencyHeld: false)

proc tryAcquire*(ip: string, isUpload: bool): AcquireResult =
    ## Applies the chained global limiters (+ uploads policy). On success the caller MUST call
    ## `releaseConcurrency` when the request finishes.
    withIpState(ip, nowSec, st):
        if not slidingTry(st.req, nowSec, gPerIpLimit.int64):
            return Rejected

        if not slidingTry(gGlobal, nowSec, gGlobalLimit.int64):
            return Rejected

        if gConcurrent >= gConcurrencyLimit:
            return Rejected

        if isUpload and not fixedTry(st.up, nowSec, gUploadsLimit.int64):
            return Rejected

        gConcurrent.inc
        return AcquireResult(allowed: true, concurrencyHeld: true)

proc releaseConcurrency*() =
    withLock gLock:
        if gConcurrent > 0: gConcurrent.dec

# ---- paste-creation burst / penalty box ------------------------------------

type Decision* = object
    allowed*: bool
    retryAfterSeconds*: int
    penalized*: bool

proc allow(penalized: bool): Decision =
    Decision(allowed: true, retryAfterSeconds: 0, penalized: penalized)

proc deny(retryAfterSeconds: int, penalized: bool): Decision =
    Decision(allowed: false, retryAfterSeconds: retryAfterSeconds, penalized: penalized)

proc checkPasteCreate*(ip: string): Decision =
    ## The per-attempt paste-creation decision (burst window + penalty box).
    withIpState(ip, nowSec, st):
        # In the penalty box: one paste per interval regardless of how long ago the burst was.
        if nowSec < st.penaltyUntil:
            let sinceLast = nowSec - st.lastAllowed
            if sinceLast < gPastePenaltyIntervalSeconds:
                return deny(int(gPastePenaltyIntervalSeconds.int64 - sinceLast), penalized = true)
            st.lastAllowed = nowSec
            return allow(penalized = true)

        # Normal mode: drop timestamps aged out of the rolling window.
        while st.recent.len > 0 and nowSec - st.recent.peekFirst() >= gPasteWindowSeconds:
            discard st.recent.popFirst()

        # Over the burst limit -> trip the penalty and reject this paste.
        if st.recent.len >= gPasteBurstLimit:
            st.penaltyUntil = nowSec + gPastePenaltySeconds
            st.recent.clear()
            return deny(gPastePenaltyIntervalSeconds, penalized = true)

        st.recent.addLast(nowSec)
        st.lastAllowed = nowSec
        return allow(penalized = false)

# ---- HTTP adapters (framework middleware + rejection helper) ----------------

const BusyBody = errorJson("Server busy or rate limit exceeded. Please retry shortly.")

proc rateLimit*(isUpload: bool): Middleware[AppConfig] =
    ## Request middleware: acquire on the way in — 503 + Retry-After if any tier rejects — and
    ## release the concurrency slot on the way out. `isUpload` selects the stricter per-IP uploads
    ## policy. Composed as the outermost middleware (dispatch.nim), so it also covers 404s. Each
    ## call returns a fresh per-request closure that captures the matched route's upload flag.
    result = proc(ctx: Ctx[AppConfig], next: Next) {.gcsafe.} =
        {.cast(gcsafe).}:
            let acq = tryAcquire(ctx.ip, isUpload)
            if not acq.allowed:
                ctx.req.respond(503, BusyBody, extraHeaders = [("Retry-After", "10")])
                return
            try:
                next()
            finally:
                if acq.concurrencyHeld: releaseConcurrency()

proc rejectPasteLimit*(ctx: Ctx[AppConfig], d: Decision): bool =
    ## Turn a `checkPasteCreate` decision into an HTTP outcome: returns true (and responds 429) when
    ## the paste is rate-limited; false when it's allowed and the handler should proceed.
    if d.allowed: return false
    let msg =
        if d.penalized:
            "Too many pastes. You've been rate-limited to 1 paste per minute for a while — please slow down."
        else:
            "Too many pastes in a short time. Please wait a moment and try again."
    let body = $(%*{
        "error": msg,
        "retryAfterSeconds": d.retryAfterSeconds,
        "penalized": d.penalized,
    })
    ctx.req.respond(429, body, extraHeaders = [("Retry-After", $d.retryAfterSeconds)])
    true
