## Entry point for the Nim Pastebin backend.
## Wires config -> stores/services -> route table, then hands off to the framework's `serve`, which
## owns the HTTP server + per-request glue. Listens on port 8080 behind nginx.

import std/strformat
import config
import common/templates
referencing blobstore
referencing ntfy
referencing clientip
referencing accesslog
referencing pastecache
referencing writequeue
referencing db
import webframework/server
import endpoints/routes, endpoints/admin/guard

proc main() =
    let cfg = config.loadConfig()

    db.initDb(cfg.sqlitePath)
    blobstore.initBlobStore(cfg.blobStoragePath)
    writequeue.initWriteQueue(cfg.cacheMaxBytes)
    # Derived, not its own env var: the read cache holds display shapes only (inline content or an
    # 8 KB preview), so a quarter of the write budget is plenty.
    pastecache.initPasteCache(cfg.cacheMaxBytes div 4)
    guard.initAdminGuard()
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
        requestTimeoutMs: cfg.requestTimeoutMs)
    serve(registerRoutes(), cfg, serverCfg, resolveIp = clientip.resolveClientIp)

when isMainModule:
    main()
