## The app's HTTP composition root: the route table + registration DSL, and `handle` — the
## per-request entry the framework calls on each worker thread. The generic per-request flow
## (match → build context → run middleware chain → handler/404) lives in the framework
## (webframework/dispatcher); here we only supply the app-specific pieces: the route payload, the
## client-IP resolver, the not-found handler, and the cross-cutting policy chain (the rate limiter —
## see ratelimit.nim). Runs on the server workers. (Admin auth isn't composed here — admin handlers
## call requireAdmin upfront; see endpoints/admin/guard.)

import webframework/[httpserver, router, middleware, dispatcher]
import ../config, ../clientip, ../ratelimit
import context

type
    RoutePayload = object
        handler: EndpointHandler
        upload: bool              ## use the dedicated uploads rate-limit policy

    RouteTable* = Router[RoutePayload]
        ## The app's route table (registerRoutes' return type in routes.nim).

var
    gRoutes: RouteTable   ## built once at startup (initRoutes), only read on the worker threads.
    gCfg: AppConfig       ## effective config, likewise write-once before the workers start.

proc get*(r: var RouteTable, pattern: string, handler: EndpointHandler) =
    r.add("GET", pattern, RoutePayload(handler: handler, upload: false))

proc post*(r: var RouteTable, pattern: string, handler: EndpointHandler, upload = false) =
    r.add("POST", pattern, RoutePayload(handler: handler, upload: upload))

proc delete*(r: var RouteTable, pattern: string, handler: EndpointHandler) =
    r.add("DELETE", pattern, RoutePayload(handler: handler, upload: false))

# Param-binding overloads: deliver a route's `{param}` captures as explicit args after `ctx`, so a
# handler for `/…/{id}` can take `(ctx: Ctx, id: string)` instead of reaching into `ctx.params`.
# These must be templates, not procs: each expands around the concrete handler symbol at the call
# site, so the generated `proc(ctx)` wrapper references a global (no closure capture) and stays a
# plain nimcall handler the route table can store. Args bind in pattern order.
template get*(r: var RouteTable, pattern: string, handler: proc(ctx: Ctx, id: string) {.nimcall.}) =
    r.get(pattern, proc(ctx: Ctx) {.nimcall.} = handler(ctx, ctx.params[0]))

template get*(r: var RouteTable, pattern: string, handler: proc(ctx: Ctx, a, b: string) {.nimcall.}) =
    r.get(pattern, proc(ctx: Ctx) {.nimcall.} = handler(ctx, ctx.params[0], ctx.params[1]))

template post*(r: var RouteTable, pattern: string, handler: proc(ctx: Ctx, id: string) {.nimcall.}, upload = false) =
    r.post(pattern, proc(ctx: Ctx) {.nimcall.} = handler(ctx, ctx.params[0]), upload)

template post*(r: var RouteTable, pattern: string, handler: proc(ctx: Ctx, a, b: string) {.nimcall.}, upload = false) =
    r.post(pattern, proc(ctx: Ctx) {.nimcall.} = handler(ctx, ctx.params[0], ctx.params[1]), upload)

template delete*(r: var RouteTable, pattern: string, handler: proc(ctx: Ctx, id: string) {.nimcall.}) =
    r.delete(pattern, proc(ctx: Ctx) {.nimcall.} = handler(ctx, ctx.params[0]))

template delete*(r: var RouteTable, pattern: string, handler: proc(ctx: Ctx, a, b: string) {.nimcall.}) =
    r.delete(pattern, proc(ctx: Ctx) {.nimcall.} = handler(ctx, ctx.params[0], ctx.params[1]))

proc initRoutes*(r: RouteTable, cfg: AppConfig) =
    ## Install the route table + config. Call once at startup, before the workers start.
    gRoutes = r
    gCfg = cfg

proc notFound(ctx: Ctx) =
    ctx.respondError(404, "Not found")

proc handlerFor(found: bool, p: RoutePayload): EndpointHandler {.gcsafe.} =
    if found: p.handler else: notFound

proc chainFor(found: bool, p: RoutePayload): seq[Middleware[AppConfig]] {.gcsafe.} =
    # The rate limiter wraps every request (matched or 404) as the outermost middleware.
    @[rateLimit(isUpload = found and p.upload)]

proc handle*(req: Request) {.nimcall, gcsafe.} =
    ## The framework's dispatch hook (a RequestHandler), run on each worker thread.
    {.cast(gcsafe).}:
        dispatchRequest(gRoutes, gCfg, req, resolveClientIp, handlerFor, chainFor)
