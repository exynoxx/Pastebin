## Generic request dispatcher: the per-request flow that ties the router, the context, and the
## middleware chain together.
##
## App-agnostic — it resolves the client id, matches the route, builds the `Ctx[E]`, and runs the
## middleware chain around the matched handler (or the app's not-found handler). The app injects
## the three things the framework can't know: how to resolve the client id, the handler to serve
## when nothing matches, and the global middleware chain. Runs on the server worker threads.
##
## The common no-middleware path allocates NO per-request closures — the matched handler is called
## directly. (An earlier design wrapped the handler/chain lookup in two lambdas built on every
## request; profiling showed their allocation + refcounted teardown dominated CPU, and — being
## cyclic heap objects freed concurrently by every worker — they were what raced ORC's global
## cycle collector into intermittent SIGSEGVs. See bench/ + docs/PERFORMANCE.md.)

import httpserver, context, router, middleware

proc dispatchRequest*[E](
        router: Router[Handler[E]], cfg: E, req: Request,
        resolveIp: proc(req: Request): string {.gcsafe.},
        notFound: Handler[E], global: seq[Middleware[E]]) {.gcsafe.} =
    {.cast(gcsafe).}:
        let ip = resolveIp(req)
        let m = router.match(req.httpMethod, req.path)
        let ctx = Ctx[E](req: req, ip: ip, params: m.params, cfg: cfg)
        let handler = if m.found: m.payload else: notFound
        if global.len == 0:
            handler(ctx)                                 # common case: no closures built at all
        else:
            # Only the middleware onion needs a per-request `final` closure — apps that register
            # no global middleware (the hot path above) never pay for it.
            runChain(ctx, global, proc() {.gcsafe.} =
                {.cast(gcsafe).}: handler(ctx))
