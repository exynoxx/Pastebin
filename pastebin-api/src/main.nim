## Entry point for the Nim Pastebin backend.
## Wires config -> stores/services -> route table, then hands off to the framework's `serve`, which
## owns the HTTP server + per-request glue. Listens on port 8080 behind nginx.

import std/strformat
import config, db, blobstore, ratelimit, ntfy
import webframework/server
import endpoints/dispatch, endpoints/routes, endpoints/admin/guard

proc main() =
    let cfg = loadConfig()

    initDb(cfg.sqlitePath)
    initBlobStore(cfg.blobStoragePath)
    initAdminGuard()
    initRateLimiter(cfg)
    initNtfy(cfg)
    initRoutes(registerRoutes(), cfg)

    stdout.writeLine(&"pastebin-api (nim) listening on 0.0.0.0:{cfg.port}" &
        &"  db={cfg.sqlitePath}  blobs={cfg.blobStoragePath}" &
        &"  workers={cfg.workerThreads}")
    stdout.flushFile()

    serve(
        port = cfg.port,
        numThreads = cfg.workerThreads,
        bodySpillThreshold = cfg.inlinePasteMaxBytes,
        maxBodyBytes = cfg.maxRequestBytes,
        networkLog = cfg.networkLog,
        dispatch = handle)

when isMainModule:
    main()
