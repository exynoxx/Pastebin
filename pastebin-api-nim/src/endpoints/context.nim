## App request context — specialises the framework's generic context for this service and adds the
## app-specific response helper. Endpoint handlers `import ../context` and get, from one import:
## `Ctx` (bound to this app's config), `Request`, `respond`/`respondFile`, `AppConfig`,
## `errorJson`/`respondError`, and `rejectPasteGuard`. JSON response builders are no longer central:
## each lives in its own vertical slice (e.g. endpoints/files/json, or inline in the handler).

import std/json
import ../framework/server
import ../framework/context as fctx
import ../config, ../pasteguard

export server, config
export fctx.errorJson, fctx.respondError

type
    Ctx* = fctx.Ctx[AppConfig]
        ## The framework's generic context bound to this app's config bundle.
    EndpointHandler* = fctx.Handler[AppConfig]
        ## Uniform handler signature the app's route table dispatches to.

proc rejectPasteGuard*(ctx: Ctx, d: Decision): bool =
    ## Returns true (and responds 429) when the paste is rate-limited; false when allowed.
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
