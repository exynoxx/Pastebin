## Umbrella + entry point. Re-exports the whole framework and defines the public API: `serve` —
## build a `RouteTable[E]`, hand it the app state, and serve (blocking). Everything it's built on
## (raw per-request dispatch, the optional access log) is private below.

import std/strutils
import httpserver, context, router, middleware, dispatcher, routetable
export httpserver, context, router, middleware, dispatcher, routetable

type
    ServerConfig* = object
        port*: int
        numThreads*: int
        bodySpillThreshold*: int   ## bodies larger than this stream to a temp file instead of RAM
        maxBodyBytes*: int64       ## hard cap; larger Content-Length is rejected with 413
        networkLog*: bool

    ResolveIp* = proc(req: Request): string {.gcsafe.}
        ## Resolves the client id used for `Ctx.ip` (rate-limit / quota / owner bucket).

var
    gDispatch: RequestHandler   ## set once in serveRaw(), read on the workers
    gNetworkLog: bool

# Bodies live at the bottom so the public API reads first; Nim needs them declared before use.
proc serveRaw(port, numThreads, bodySpillThreshold: int, maxBodyBytes: int64,
              networkLog: bool, dispatch: RequestHandler)
proc entry(req: Request) {.nimcall, gcsafe.}
proc defaultNotFound[E](ctx: Ctx[E]) {.nimcall, gcsafe.}

# ---- public API ------------------------------------------------------------

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

proc serve*[E](routes: RouteTable[E], state: E, config = defaultConfig(),
               resolveIp: ResolveIp = defaultResolveIp) =
    ## Serve `routes` (blocking). `state` is the app structure every handler gets via `Ctx.cfg`.
    ## Captured once into a per-instantiation global closure before workers start, so the nimcall
    ## `onRequest` (which can't close over locals) reaches it and the single-writer rule holds.
    var gRun {.global.}: proc(req: Request) {.gcsafe.}

    let notFound = if routes.notFound != nil: routes.notFound else: defaultNotFound[E]

    # Built ONCE here, then called (not rebuilt) per request — the router, state, notFound handler
    # and global chain are all fixed after startup, so nothing per-request needs capturing. The
    # dispatcher is handed these values directly rather than via per-request callback closures.
    gRun = proc(req: Request) {.gcsafe.} =
        {.cast(gcsafe).}:
            dispatchRequest(routes.router, state, req, resolveIp, notFound, routes.global)

    proc onRequest(req: Request) {.nimcall, gcsafe.} =
        {.cast(gcsafe).}: gRun(req)

    serveRaw(config.port, config.numThreads, config.bodySpillThreshold,
             config.maxBodyBytes, config.networkLog, onRequest)

# ---- private helpers -------------------------------------------------------

proc serveRaw(port, numThreads, bodySpillThreshold: int, maxBodyBytes: int64,
              networkLog: bool, dispatch: RequestHandler) =
    ## Wire a raw `dispatch` onto the HTTP server and serve (blocking). Set once, before any worker
    ## starts — the single-writer discipline listenAndServe() relies on.
    gDispatch = dispatch
    gNetworkLog = networkLog
    listenAndServe(port, numThreads, bodySpillThreshold, maxBodyBytes, entry)

proc entry(req: Request) {.nimcall, gcsafe.} =
    ## The `RequestHandler` wired into the HTTP server: optional access log, then the app's dispatch.
    {.cast(gcsafe).}:
        if gNetworkLog:
            stdout.writeLine("NETLOG " & req.httpMethod & " " & req.path)
            stdout.flushFile()
        gDispatch(req)

proc defaultNotFound[E](ctx: Ctx[E]) {.nimcall, gcsafe.} =
    ctx.respondError(404, "Not found")
