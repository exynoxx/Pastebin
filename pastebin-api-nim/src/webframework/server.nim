## Umbrella + entry point for the in-house web framework: re-exports the HTTP server, the generic
## router, the request context, and the middleware mechanism, and defines `serve`, the application
## entry point.
##
## App code imports `webframework/server` and calls `serve` to start serving. `serve` owns the
## per-request glue that used to live in main: an optional access log, then a hand-off to the app's
## dispatch. It calls down into the HTTP server's `listenAndServe`; main never touches httpserver
## directly.

import httpserver, context, router, middleware
export httpserver, context, router, middleware

var
    gDispatch: RequestHandler   ## app per-request entry; set once in serve(), read on the workers.
    gNetworkLog: bool

proc entry(req: Request) {.nimcall, gcsafe.} =
    {.cast(gcsafe).}:
        if gNetworkLog:
            stdout.writeLine("NETLOG " & req.httpMethod & " " & req.path)
            stdout.flushFile()
        gDispatch(req)

proc serve*(port, numThreads, bodySpillThreshold: int, maxBodyBytes: int64,
            networkLog: bool, dispatch: RequestHandler) =
    ## Wire the app's `dispatch` onto the HTTP server and serve (blocking). `dispatch`/`networkLog`
    ## are set once here, before any worker starts, and only read on the workers — the same
    ## single-writer discipline listenAndServe() relies on for its handler.
    gDispatch = dispatch
    gNetworkLog = networkLog
    listenAndServe(port, numThreads, bodySpillThreshold, maxBodyBytes, entry)
