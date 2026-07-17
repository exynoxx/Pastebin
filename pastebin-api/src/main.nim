## Entry point for the Nim Pastebin backend.
## Wires config -> stores/services -> route table, then hands off to the framework's `serve`, which
## owns the HTTP server + per-request glue. Listens on port 8080 behind nginx.

import std/strformat
import config, blobstore, ratelimit, ntfy, clientip, accesslog, pastecache
from db import nil
import webframework/server
import endpoints/routes, endpoints/admin/guard

proc main() =
    let cfg = loadConfig()

    db.initDb(cfg.sqlitePath)
    initBlobStore(cfg.blobStoragePath)
    initPasteCache(cfg)
    initAdminGuard()
    initRateLimiter(cfg)
    initAccessLog(cfg)
    initNtfy(cfg)

    stdout.writeLine(&"pastebin-api (nim) listening on 0.0.0.0:{cfg.port}" &
        &"  db={cfg.sqlitePath}  blobs={cfg.blobStoragePath}" &
        &"  workers={cfg.workerThreads}")
    stdout.flushFile()

    let serverCfg = ServerConfig(
        port: cfg.port,
        numThreads: cfg.workerThreads,
        bodySpillThreshold: cfg.inlinePasteMaxBytes,
        maxBodyBytes: cfg.maxRequestBytes,
        networkLog: cfg.networkLog)
    serve(registerRoutes(), cfg, serverCfg, resolveIp = resolveClientIp)

when isMainModule:
    main()
