## Generic per-request context + response helpers for endpoint handlers.
##
## App-agnostic: `Ctx[E]` carries the framework-level request state — the HTTP request, the
## resolved client identifier, and the captured `{param}` path segments — plus an app-supplied
## dependency bundle `cfg: E` (e.g. the application config). Handlers all share the uniform shape
## `proc(ctx: Ctx[E])`, so a single route table can dispatch to any of them (see router.nim).
##
## Re-exports `httpserver` so an endpoint that imports the app's context gets `Request`, `respond`,
## `respondFile`, the header/body/query helpers, etc. from one import.

import std/json
import httpserver

export httpserver

type
    Ctx*[E] = object
        req*: Request         ## the HTTP request being served
        ip*: string           ## resolved client identifier (rate-limit / quota / owner bucket)
        params*: seq[string]  ## path parameters, in pattern order (e.g. the {id})
        cfg*: E               ## app-supplied dependencies (e.g. the effective AppConfig)

    Handler*[E] = proc(ctx: Ctx[E]) {.nimcall.}
        ## Uniform handler signature the router dispatches to.

func errorJson*(msg: string): string =
    ## The shared error envelope emitted across the API: {"error": "..."}.
    $(%*{"error": msg})

proc respondError*(req: Request, code: int, msg: string) =
    req.respond(code, errorJson(msg))

proc respondError*[E](ctx: Ctx[E], code: int, msg: string) =
    ctx.req.respond(code, errorJson(msg))

# ---- handler control-flow templates ----------------------------------------
# These early-`return` from the enclosing handler, so they must be templates, not procs.
# `isNone`/`get` are resolved at the call site (every handler using fetchOr404 imports std/options).

template fetchOr404*(ctx, opt, msg: untyped): untyped =
    ## Yield the value inside an `Option`, or respond 404 with `msg` and return from the handler.
    let optVal = opt
    if optVal.isNone:
        ctx.respondError(404, msg)
        return
    optVal.get

template parseJsonBodyOr400*(ctx: untyped): JsonNode =
    ## Parse the request body as JSON, or respond 400 and return from the handler.
    var node: JsonNode
    try:
        node = parseJson(ctx.req.bodyString())
    except CatchableError:
        ctx.respondError(400, "Invalid request body")
        return
    node
