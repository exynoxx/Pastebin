## Entry point for the Nim Pastebin backend — a drop-in replacement for the .NET pastebin-api.
## Wires config -> stores/services -> the minimal HTTP server, on port 8080 behind nginx.

import config, db, blobstore, pasteguard, adminguard, ratelimit, ntfy, httpserver, router

var gConfig: AppConfig

proc handler(req: Request) {.gcsafe.} =
    # gConfig is set once before the worker threads start and only read thereafter.
    {.cast(gcsafe).}:
        if gConfig.networkLog:
            stdout.writeLine("NETLOG " & req.httpMethod & " " & req.path)
            stdout.flushFile()
        route(gConfig, req)

proc main() =
    gConfig = loadConfig()

    initDb(gConfig.sqlitePath)
    initBlobStore(gConfig.blobStoragePath)
    initPasteGuard(gConfig)
    initAdminGuard()
    initRateLimiter(gConfig)
    initNtfy(gConfig)

    stdout.writeLine("pastebin-api (nim) listening on 0.0.0.0:" & $gConfig.port &
        "  db=" & gConfig.sqlitePath & "  blobs=" & gConfig.blobStoragePath &
        "  workers=" & $gConfig.workerThreads)
    stdout.flushFile()

    serve(
        port = gConfig.port,
        numThreads = gConfig.workerThreads,
        bodySpillThreshold = gConfig.inlinePasteMaxBytes,
        maxBodyBytes = gConfig.maxRequestBytes,
        handler = handler)

when isMainModule:
    main()
