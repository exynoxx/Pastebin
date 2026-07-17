## Overload protection: a single global concurrency cap.
##
## `rateLimit` runs on EVERY request (registered as the outermost global middleware after the access
## log — see endpoints/routes.nim, so it also covers 404s). It admits a request only while fewer than
## `globalConcurrency` requests are already in flight; otherwise it answers 503 + Retry-After: 10. The
## slot is released when the request finishes.
##
## This is the only limiter left here. The other protections live with the feature they guard:
##   - paste-creation burst/rate limiting (429) -> pastecache.admit
##   - per-IP storage quota                      -> quota.nim
##   - admin brute-force lockout                 -> endpoints/admin/guard.nim
##
## Under Nim's shared heap the counter is reachable from all worker threads, so a single process-wide
## lock guards it.

import std/locks
import config
import webframework/[httpserver, context, middleware]

const
    BusyBody = errorJson("Server busy. Please retry shortly.")

var
    gLock: Lock
    gConcurrent: int
    gConcurrencyLimit: int

# ---- public API ------------------------------------------------------------

proc initRateLimiter*(cfg: AppConfig) =
    initLock(gLock)
    gConcurrent = 0
    gConcurrencyLimit = cfg.globalConcurrency

proc rateLimit*(): Middleware[AppConfig] =
    ## Request middleware: admit while the in-flight count is under the cap (503 + Retry-After
    ## otherwise), and release the slot on the way out.
    result = proc(ctx: Ctx[AppConfig], next: Next) {.gcsafe.} =
        {.cast(gcsafe).}:
            var admitted = false
            withLock gLock:
                if gConcurrent < gConcurrencyLimit:
                    gConcurrent.inc
                    admitted = true
            if not admitted:
                ctx.req.respond(503, BusyBody, extraHeaders = [("Retry-After", "10")])
                return
            try:
                next()
            finally:
                withLock gLock:
                    if gConcurrent > 0: gConcurrent.dec
