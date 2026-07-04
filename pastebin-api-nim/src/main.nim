## Entry point for the Nim Pastebin backend — a drop-in replacement for the .NET pastebin-api.
## Wires config -> stores/services -> route table, then hands off to the framework's `run`, which
## owns the HTTP server + per-request glue. Listens on port 8080 behind nginx.

import std/strformat
import config, db, blobstore, pasteguard, adminguard, ratelimit, ntfy
import framework
import endpoints/dispatch, endpoints/routes

proc main() =
    let cfg = loadConfig()

    initDb(cfg.sqlitePath)
    initBlobStore(cfg.blobStoragePath)
    initPasteGuard(cfg)
    initAdminGuard()
    initRateLimiter(cfg)
    initNtfy(cfg)
    initRoutes(registerRoutes(), cfg)

    stdout.writeLine(&"pastebin-api (nim) listening on 0.0.0.0:{cfg.port}" &
        &"  db={cfg.sqlitePath}  blobs={cfg.blobStoragePath}" &
        &"  workers={cfg.workerThreads}")
    stdout.flushFile()

    run(
        port = cfg.port,
        numThreads = cfg.workerThreads,
        bodySpillThreshold = cfg.inlinePasteMaxBytes,
        maxBodyBytes = cfg.maxRequestBytes,
        networkLog = cfg.networkLog,
        dispatch = handle)

when isMainModule:
    main()
