## The app's HTTP composition root: the route table + registration DSL, and `handle` — the
## per-request entry the framework calls on each worker thread. It resolves the client IP, matches
## the route, then composes the cross-cutting policies (rate limiter, admin gate — see policies.nim)
## around the matched endpoint via the framework's middleware chain. Runs on the server workers.

import ../framework/[server, router, middleware]
import ../config, ../clientip
import context, policies

type
    RoutePayload = object
        handler: EndpointHandler
        admin: bool               ## require a valid X-Admin-Token (fail-closed + lockout)
        upload: bool              ## use the dedicated uploads rate-limit policy

    RouteTable* = Router[RoutePayload]
        ## The app's route table (registerRoutes' return type in routes.nim).

var
    gRoutes: RouteTable   ## built once at startup (initRoutes), only read on the worker threads.
    gCfg: AppConfig       ## effective config, likewise write-once before the workers start.

# ---- registration DSL (used by routes.nim) ---------------------------------

proc get*(r: var RouteTable, pattern: string, handler: EndpointHandler, admin = false) =
    r.add("GET", pattern, RoutePayload(handler: handler, admin: admin, upload: false))

proc post*(r: var RouteTable, pattern: string, handler: EndpointHandler,
           admin = false, upload = false) =
    r.add("POST", pattern, RoutePayload(handler: handler, admin: admin, upload: upload))

proc delete*(r: var RouteTable, pattern: string, handler: EndpointHandler, admin = false) =
    r.add("DELETE", pattern, RoutePayload(handler: handler, admin: admin, upload: false))

proc initRoutes*(r: RouteTable, cfg: AppConfig) =
    ## Install the route table + config. Call once at startup, before the workers start.
    gRoutes = r
    gCfg = cfg

# ---- per-request entry -----------------------------------------------------

proc route(req: Request) =
    let ip = resolveClientIp(req)
    let m = gRoutes.match(req.httpMethod, splitPath(req.path))
    let ctx = Ctx(req: req, ip: ip, params: m.params, cfg: gCfg)

    # The rate limiter is outermost so it wraps every request (matched or 404); the admin gate is
    # added only for admin routes. Both are per-request closures (policies.nim).
    var chain: seq[Middleware[AppConfig]]
    chain.add rateLimit(isUpload = m.found and m.payload.upload)
    if m.found and m.payload.admin:
        chain.add adminGate()

    let final = proc() {.gcsafe.} =
        {.cast(gcsafe).}:
            if not m.found:
                respondError(req, 404, "Not found")
            else:
                m.payload.handler(ctx)

    runChain(ctx, chain, final)

proc handle*(req: Request) {.nimcall, gcsafe.} =
    ## The framework's dispatch hook (a RequestHandler), run on each worker thread.
    {.cast(gcsafe).}:
        route(req)
