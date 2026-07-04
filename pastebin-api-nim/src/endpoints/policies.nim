## Cross-cutting request policies, packaged as framework middleware: the 3-tier rate limiter
## (+ uploads policy) and the fail-closed admin-token gate. `route` (dispatch.nim) composes these
## around the matched endpoint via the framework's middleware chain. Each factory returns a
## per-request closure so it can capture matched-route facts (e.g. whether it's an upload route).

import std/os
import ../framework/[server, context, middleware]
import ../config, ../ratelimit, ../adminguard

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

proc adminGate*(): Middleware[AppConfig] =
    ## Fail-closed admin auth: an unset ADMIN_TOKEN (or a mismatch) rejects with 401. The token is
    ## short, so adminguard makes guessing expensive — an escalating per-IP lockout (instant 429
    ## while cooling down) plus a fixed delay + constant-time compare on each failed attempt.
    result = proc(ctx: Ctx[AppConfig], next: Next) {.gcsafe.} =
        {.cast(gcsafe).}:
            let gate = adminPrecheck(ctx.ip)
            if gate.lockedOut:
                ctx.req.respond(429, errorJson("Too many failed admin attempts. Try again later."),
                    extraHeaders = [("Retry-After", $gate.retryAfterSeconds)])
                return
            if ctx.cfg.adminToken.len == 0 or
               not constantTimeEq(ctx.req.header("X-Admin-Token"), ctx.cfg.adminToken):
                registerAdminFailure(ctx.ip)
                sleep(AdminFailPenaltyMs)
                ctx.req.respond(401, errorJson("Unauthorized"))
                return
            clearAdminFailures(ctx.ip)
            next()
