## Entry point for the Nim Pastebin backend.
## Wires config -> stores/services -> route table, then hands off to the framework's `serve`, which
## owns the HTTP server + per-request glue. Listens on port 8080 behind nginx.

import std/strformat
import config
import common/controlflow
importuse blobstore
importuse ratelimit
importuse ntfy
importuse clientip
importuse accesslog
importuse pastecache
importuse db
import webframework/server
import endpoints/routes, endpoints/admin/guard

proc main() =
    let cfg = config.loadConfig()

    db.initDb(cfg.sqlitePath)
    blobstore.initBlobStore(cfg.blobStoragePath)
    pastecache.initPasteCache(cfg)
    initAdminGuard()
    ratelimit.initRateLimiter(cfg)
    accesslog.initAccessLog(cfg)
    ntfy.initNtfy(cfg)

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
    serve(registerRoutes(), cfg, serverCfg, resolveIp = clientip.resolveClientIp)

when isMainModule:
    main()
