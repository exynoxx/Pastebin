## The route-registration facade. `RouteTable[E]` holds the routes, the global middleware chain,
## and an optional custom 404, generic over `E` (the app-supplied state every handler receives via
## `Ctx[E]`). Build it once at startup with the verb procs and `use`, then hand it to `run`.

import router, context, middleware

export Handler        # so an app can name Handler[E] without importing context directly

type
    RouteTable*[E] = object
        router*: Router[Handler[E]]
        global*: seq[Middleware[E]]     ## runs on every request, in registration order
        notFound*: Handler[E]           ## nil => framework default 404

# One proc per verb so call sites read as a table: result.get(...), result.post(...).

proc get*[E](t: var RouteTable[E], path: string, handler: Handler[E]) =
    t.router.add("GET", path, handler)

proc post*[E](t: var RouteTable[E], path: string, handler: Handler[E]) =
    t.router.add("POST", path, handler)

proc delete*[E](t: var RouteTable[E], path: string, handler: Handler[E]) =
    t.router.add("DELETE", path, handler)

proc put*[E](t: var RouteTable[E], path: string, handler: Handler[E]) =
    t.router.add("PUT", path, handler)

proc patch*[E](t: var RouteTable[E], path: string, handler: Handler[E]) =
    t.router.add("PATCH", path, handler)

# ---- param-binding overloads ------------------------------------------------
# Deliver a route's `{param}` captures as explicit args after `ctx`, so a handler for `/…/{id}` can
# take `(ctx: Ctx[E], id: string)` instead of reaching into `ctx.params`. These must be templates,
# not procs: each expands around the concrete handler symbol at the call site, so the generated
# `proc(ctx)` wrapper references a global (no closure capture) and stays a plain nimcall handler the
# route table can store. Args bind in pattern order.

template get*[E](t: var RouteTable[E], path: string, handler: proc(ctx: Ctx[E], param1: string) {.nimcall.}) =
    t.get(path, proc(ctx: Ctx[E]) {.nimcall.} = handler(ctx, ctx.params[0]))

template get*[E](t: var RouteTable[E], path: string, handler: proc(ctx: Ctx[E], param1, param2: string) {.nimcall.}) =
    t.get(path, proc(ctx: Ctx[E]) {.nimcall.} = handler(ctx, ctx.params[0], ctx.params[1]))

template post*[E](t: var RouteTable[E], path: string, handler: proc(ctx: Ctx[E], param1: string) {.nimcall.}) =
    t.post(path, proc(ctx: Ctx[E]) {.nimcall.} = handler(ctx, ctx.params[0]))

template post*[E](t: var RouteTable[E], path: string, handler: proc(ctx: Ctx[E], param1, param2: string) {.nimcall.}) =
    t.post(path, proc(ctx: Ctx[E]) {.nimcall.} = handler(ctx, ctx.params[0], ctx.params[1]))

template delete*[E](t: var RouteTable[E], path: string, handler: proc(ctx: Ctx[E], param1: string) {.nimcall.}) =
    t.delete(path, proc(ctx: Ctx[E]) {.nimcall.} = handler(ctx, ctx.params[0]))

template delete*[E](t: var RouteTable[E], path: string, handler: proc(ctx: Ctx[E], param1, param2: string) {.nimcall.}) =
    t.delete(path, proc(ctx: Ctx[E]) {.nimcall.} = handler(ctx, ctx.params[0], ctx.params[1]))

# ---- global middleware + 404 ------------------------------------------------

proc use*[E](t: var RouteTable[E], m: Middleware[E]) =
    ## Register a global middleware. The first `use` is the outermost layer of the onion.
    t.global.add m

proc onNotFound*[E](t: var RouteTable[E], handler: Handler[E]) =
    ## Override the default JSON 404 (still wrapped by the global chain).
    t.notFound = handler
