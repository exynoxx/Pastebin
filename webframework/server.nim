## Umbrella + entry point. Re-exports the whole framework and defines the two ways to serve:
## `run` (build a `RouteTable[E]` and hand it the app state — the usual path) and the lower-level
## `serve` it's built on (raw per-request `dispatch`, plus the optional access log).

import std/strutils
import httpserver, context, router, middleware, dispatcher, routetable
export httpserver, context, router, middleware, dispatcher, routetable

# ---- low-level entry: raw dispatch -----------------------------------------

var
    gDispatch: RequestHandler   ## set once in serve(), read on the workers
    gNetworkLog: bool

proc entry(req: Request) {.nimcall, gcsafe.} =
    {.cast(gcsafe).}:
        if gNetworkLog:
            stdout.writeLine("NETLOG " & req.httpMethod & " " & req.path)
            stdout.flushFile()
        gDispatch(req)

proc serve*(port, numThreads, bodySpillThreshold: int, maxBodyBytes: int64,
            networkLog: bool, dispatch: RequestHandler) =
    ## Wire a raw `dispatch` onto the HTTP server and serve (blocking). Set once, before any worker
    ## starts — the single-writer discipline listenAndServe() relies on.
    gDispatch = dispatch
    gNetworkLog = networkLog
    listenAndServe(port, numThreads, bodySpillThreshold, maxBodyBytes, entry)

# ---- high-level entry: RouteTable ------------------------------------------

type
    ServerConfig* = object
        port*: int
        numThreads*: int
        bodySpillThreshold*: int   ## bodies larger than this stream to a temp file instead of RAM
        maxBodyBytes*: int64       ## hard cap; larger Content-Length is rejected with 413
        networkLog*: bool

    ResolveIp* = proc(req: Request): string {.gcsafe.}
        ## Resolves the client id used for `Ctx.ip` (rate-limit / quota / owner bucket).

proc defaultConfig*(): ServerConfig =
    ServerConfig(port: 8080, numThreads: 4, bodySpillThreshold: 1 shl 20,
                 maxBodyBytes: 100'i64 shl 20, networkLog: false)

proc defaultResolveIp*(req: Request): string {.gcsafe.} =
    ## Behind nginx: trust the first `X-Forwarded-For` hop; fall back to the socket peer address.
    let xff = req.header("X-Forwarded-For")
    if xff.len > 0:
        let comma = xff.find(',')
        return (if comma >= 0: xff[0 ..< comma] else: xff).strip()
    req.remoteAddress

proc defaultNotFound[E](ctx: Ctx[E]) {.nimcall, gcsafe.} =
    ctx.respondError(404, "Not found")

proc run*[E](routes: RouteTable[E], state: E, config = defaultConfig(),
             resolveIp: ResolveIp = defaultResolveIp) =
    ## Serve `routes` (blocking). `state` is the app structure every handler gets via `Ctx.cfg`.
    ## Captured once into a per-instantiation global closure before workers start, so the nimcall
    ## `onRequest` (which can't close over locals) reaches it and the single-writer rule holds.
    var gRun {.global.}: proc(req: Request) {.gcsafe.}

    let notFound = if routes.notFound != nil: routes.notFound else: defaultNotFound[E]

    gRun = proc(req: Request) {.gcsafe.} =
        {.cast(gcsafe).}:
            dispatchRequest(
                routes.router, state, req, resolveIp,
                proc(found: bool, payload: Handler[E]): Handler[E] {.gcsafe.} =
                    (if found: payload else: notFound),
                proc(found: bool, payload: Handler[E]): seq[Middleware[E]] {.gcsafe.} =
                    routes.global)

    proc onRequest(req: Request) {.nimcall, gcsafe.} =
        {.cast(gcsafe).}: gRun(req)

    serve(config.port, config.numThreads, config.bodySpillThreshold,
          config.maxBodyBytes, config.networkLog, onRequest)
