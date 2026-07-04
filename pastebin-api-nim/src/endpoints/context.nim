## Shared request context + response helpers for the endpoint handlers.
##
## Every handler has the uniform shape `proc(ctx: Ctx)` — the equivalent of an ASP.NET
## minimal-API delegate — so they can all sit in one route table (see routes.nim). `Ctx` carries
## the dependencies a handler needs: the app config, the request, the resolved client IP, and any
## `{param}` path segments the router captured.
##
## Re-exports httpserver/config/jsonbuild so each endpoint file gets Request, respond(), AppConfig
## and the JSON builders from a single `import ../context`.

import std/json
import ../httpserver, ../config, ../jsonbuild, ../pasteguard

export httpserver, config, jsonbuild

type
    Ctx* = object
        cfg*: AppConfig       ## effective configuration (limits, quotas, paths)
        req*: Request         ## the HTTP request being served
        ip*: string           ## resolved client IP (rate-limit / quota / owner bucket)
        params*: seq[string]  ## path parameters, in pattern order (e.g. the {id})

    EndpointHandler* = proc(ctx: Ctx) {.nimcall.}
        ## Uniform handler signature the router dispatches to.

proc respondError*(req: Request, code: int, msg: string) =
    req.respond(code, errorJson(msg))

proc respondError*(ctx: Ctx, code: int, msg: string) =
    ctx.req.respond(code, errorJson(msg))

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
