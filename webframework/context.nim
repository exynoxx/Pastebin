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
        req*: Request
        ip*: string           ## resolved client identifier (rate-limit / quota / owner bucket)
        params*: seq[string]  ## path parameters, in pattern order (e.g. the {id})
        cfg*: E               ## app-supplied dependencies (e.g. the effective AppConfig)

    Handler*[E] = proc(ctx: Ctx[E]) {.nimcall.}
        ## Uniform handler signature the router dispatches to.

# ---- request-info accessors ------------------------------------------------
# Thin conveniences so a handler reads request info off its Ctx instead of reaching through `.req`.

func header*[E](ctx: Ctx[E], name: string): string = ctx.req.header(name)
func queryParam*[E](ctx: Ctx[E], name: string): string = ctx.req.queryParam(name)
func httpMethod*[E](ctx: Ctx[E]): string = ctx.req.httpMethod
func path*[E](ctx: Ctx[E]): string = ctx.req.path
func remoteAddress*[E](ctx: Ctx[E]): string = ctx.req.remoteAddress
func origin*[E](ctx: Ctx[E]): string = ctx.req.header("Origin")

proc respond*[E](ctx: Ctx[E], statusCode: int, body: string,
                 contentType = "application/json; charset=utf-8",
                 extraHeaders: openArray[(string, string)] = []) =
    ## Ctx-level counterpart to respondError, for success bodies.
    ctx.req.respond(statusCode, body, contentType, extraHeaders)

# ---- handler control-flow templates ----------------------------------------
# Early-`return`s from the enclosing handler, so it must be a template, not a proc. (The generic
# fetchOr404 lives in the shared common/ project; this one is JSON-body specific, so it stays here.)

template parseJsonBodyOr400*(ctx: untyped): JsonNode =
    ## Parse the request body as JSON, or respond 400 and return from the handler.
    var node: JsonNode
    try:
        node = parseJson(ctx.req.bodyString())
    except CatchableError:
        ctx.respondError(400, "Invalid request body")
        return
    node

func errorJson*(msg: string): string =
    ## The shared error envelope emitted across the API: {"error": "..."}.
    $(%*{"error": msg})

proc respondError*(req: Request, code: int, msg: string) =
    req.respond(code, errorJson(msg))

proc respondError*[E](ctx: Ctx[E], code: int, msg: string) =
    ctx.req.respond(code, errorJson(msg))
