# Hot-path allocation & syscall optimization

Date: 2026-07-07

## Goal

Lower per-request latency in the existing blocking thread-pool model by cutting
per-request heap allocations and syscalls. **No architecture change** — the
raw threaded server, synchronous handler API, body-spill and Range streaming
all stay exactly as they are. Analysis settled that rebasing on
`std/asynchttpserver` does *not* pay off (it forces futures into the handler
API against the design goal, and std has no real async file I/O, so the
streaming primitives would have to be re-offloaded to threads anyway).

## What's changing and why

Traced per small request through `handleConnection` (`httpserver.nim`), the
router, and the middleware chain. Ordered by payoff:

1. **Thread-local recv buffer** (`httpserver.nim`). Today `var chunk =
   newString(RecvChunk)` allocates and frees 64 KB on *every* request. Replace
   with a `{.threadvar.}` buffer allocated once per worker and reused across all
   requests that worker serves. Safe because a worker handles one connection at
   a time.

2. **Coalesce the response into one `send()`** (`httpserver.nim`, `respond`).
   Today a buffered response is two syscalls: status+headers, then body. Build
   one buffer (headers followed by body) and send once. `respond` is documented
   for small/JSON bodies (large payloads go through `respondFile`), so the extra
   in-memory concat is cheap and worth one fewer syscall per request.

3. **Drop the header-accumulation slice-copy** (`httpserver.nim`). Today
   `pending.add chunk[0 ..< n]` allocates a temporary each recv. Grow `pending`
   and `copyMem` the `n` received bytes straight in.

4. **`streamFileRange` partial chunk via pointer send** (`httpserver.nim`).
   Today `sock.send(buf[0 ..< n])` copies the final partial chunk on every
   download. Send from the buffer without the slice copy. (Download path only,
   not the hot small-request path — included for completeness.)

5. **Allocation-free header parsing** (`httpserver.nim`). Today
   `headerText.split("\r\n")` allocates a seq plus a `strip()` string per
   header. Walk the header block line-by-line by index and slice only the
   pieces actually stored. Win scales with header count.

6. **Framework-level allocations:**
   - **`splitPath` on the hot path** (`router.nim`, `dispatcher.nim`). Today
     every request allocates a `seq[string]` (strip + split) just to match.
     Add a hot-path matcher that walks the raw path by segment index without
     materializing a seq; keep the existing `splitPath` for route *registration*
     (startup, not hot). `params` still grows only for routes that have
     `{param}` segments.
   - **`runChain` closure ladder** (`middleware.nim`, `dispatcher.nim`). Today
     even a zero-middleware request builds the recursive `at(i)` closure chain
     plus a `final` closure. Add a fast path: when the global chain is empty,
     call the handler directly with no closures built.

## Non-goals

- No async / event loop / `std/asynchttpserver`.
- No change to the public handler signature `proc(ctx: Ctx[E])`, to
  `RouteTable`, `run`, `serve`, body-spill, or Range streaming semantics.
- No connection pooling / keep-alive (still `Connection: close`).
- No object pooling of `Request` (measured separately if it proves to matter).

## Verification

Correctness: the existing `examples/hello.nim` must still return `hello world`
on `GET /hello` and the default JSON 404 on an unknown path.

Performance: a small concurrent load client written in Nim (no `wrk`/`ab`
installed) hammers `GET /hello` with a fixed request count across K connections
(open → send → recv → close, matching the server's one-request-per-connection
model). Measure requests/sec and mean latency before and after the change on
the same machine, same params. Report the delta. A change that doesn't move the
number gets reverted rather than kept on faith.

## Risk / rollback

Each item is independent and small; they land and are verified one at a time so
a regression is bisectable. Threadvar reuse and the `copyMem`/pointer-send
changes are the only `unsafe`-ish edits — covered by the correctness check
(a wrong length or offset corrupts the response body, which the `/hello` and
404 assertions catch immediately).
