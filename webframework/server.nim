## Umbrella + entry point. Re-exports the whole framework and defines the public API: `serve` —
## build a `RouteTable[E]`, hand it the app state, and serve (blocking).

import httpserver, context, router, middleware, dispatcher, routetable
export httpserver, context, router, middleware, dispatcher, routetable

type
    ServerConfig* = object
        port*: int
        numThreads*: int
        bodySpillThreshold*: int   ## bodies larger than this stream to a temp file instead of RAM
        maxBodyBytes*: int64       ## hard cap; larger Content-Length is rejected with 413
        requestTimeoutMs*: int     ## per-socket recv/send idle timeout; a stalled client frees its worker (0 = off)

    ResolveIp* = proc(req: Request): string {.gcsafe.}
        ## Resolves the client id used for `Ctx.ip` (quota / owner bucket). Required: which hop in
        ## the proxy chain is the real client is a deployment fact the framework can't guess, and a
        ## wrong default silently collapses every user into one bucket.

# Bodies live at the bottom so the public API reads first; Nim needs them declared before use.
proc defaultNotFound[E](ctx: Ctx[E]) {.nimcall, gcsafe.}

# ---- public API ------------------------------------------------------------

proc serve*[E](routes: RouteTable[E], state: E, config: ServerConfig, resolveIp: ResolveIp) =
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

    listenAndServe(config.port, config.numThreads, config.bodySpillThreshold,
                   config.maxBodyBytes, config.requestTimeoutMs, onRequest)

# ---- private helpers -------------------------------------------------------

proc defaultNotFound[E](ctx: Ctx[E]) {.nimcall, gcsafe.} =
    ctx.respondError(404, "Not found")
