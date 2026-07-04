## Cross-cutting request policies, packaged as framework middleware: the 3-tier rate limiter
## (+ uploads policy). `route` (dispatch.nim) composes these around the matched endpoint via the
## framework's middleware chain. Each factory returns a per-request closure so it can capture
## matched-route facts (e.g. whether it's an upload route). Admin auth is NOT here — it's a pure
## precondition with no on-the-way-out work, so it lives as an upfront guard in endpoints/admin/guard.

import ../webframework/[httpserver, context, middleware]
import ../config, ../ratelimit

const BusyBody = errorJson("Server busy or rate limit exceeded. Please retry shortly.")

proc rateLimit*(isUpload: bool): Middleware[AppConfig] =
    ## Acquire on the way in — 503 + Retry-After if any tier rejects — and release the concurrency
    ## slot on the way out. `isUpload` selects the stricter per-IP uploads policy. Applies to every
    ## request (including 404s), since it wraps the whole chain as the outermost middleware.
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
