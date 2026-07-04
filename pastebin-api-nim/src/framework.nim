## Umbrella for the in-house web framework: the HTTP server, the generic router, the request
## context, and the middleware mechanism — plus `run`, the application entry point.
##
## App code imports `framework` (not `framework/server`) and calls `run` to start serving. `run`
## owns the per-request glue that used to live in main: an optional access log, then a hand-off to
## the app's dispatch. The framework calls down into the server; main never touches the server
## directly.

import framework/[server, context, router, middleware]
export server, context, router, middleware

var
    gDispatch: RequestHandler   ## app per-request entry; set once in run(), read on the workers.
    gNetworkLog: bool

proc entry(req: Request) {.nimcall, gcsafe.} =
    {.cast(gcsafe).}:
        if gNetworkLog:
            stdout.writeLine("NETLOG " & req.httpMethod & " " & req.path)
            stdout.flushFile()
        gDispatch(req)

proc run*(port, numThreads, bodySpillThreshold: int, maxBodyBytes: int64,
          networkLog: bool, dispatch: RequestHandler) =
    ## Wire the app's `dispatch` onto the HTTP server and serve (blocking). `dispatch`/`networkLog`
    ## are set once here, before any worker starts, and only read on the workers — the same
    ## single-writer discipline serve() relies on for its handler.
    gDispatch = dispatch
    gNetworkLog = networkLog
    serve(port, numThreads, bodySpillThreshold, maxBodyBytes, entry)
