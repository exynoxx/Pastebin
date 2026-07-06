## Generic request dispatcher: the per-request flow that ties the router, the context, and the
## middleware chain together.
##
## App-agnostic — it resolves the client id, matches the route, builds the `Ctx[E]`, and runs the
## middleware chain around the matched handler (or a not-found handler). The app injects the three
## things the framework can't know: how to resolve the client id, which handler a match maps to
## (and what to serve when nothing matched), and which middleware wrap the call. Runs on the
## server worker threads.

import httpserver, context, router, middleware

proc dispatchRequest*[E, P](
        routes: Router[P], cfg: E, req: Request,
        resolveIp: proc(req: Request): string {.gcsafe.},
        handlerFor: proc(found: bool, payload: P): Handler[E] {.gcsafe.},
        chainFor: proc(found: bool, payload: P): seq[Middleware[E]] {.gcsafe.}) {.gcsafe.} =
    {.cast(gcsafe).}:
        let ip = resolveIp(req)
        let m = routes.match(req.httpMethod, req.path)
        let ctx = Ctx[E](req: req, ip: ip, params: m.params, cfg: cfg)
        let handler = handlerFor(m.found, m.payload)
        let chain = chainFor(m.found, m.payload)
        if chain.len == 0:
            handler(ctx)                                 # common case: no closures built at all
        else:
            let final = proc() {.gcsafe.} =
                {.cast(gcsafe).}: handler(ctx)
            runChain(ctx, chain, final)
