## Typed application configuration, sourced from environment variables.
## Each field falls back to a sensible default when its env var is unset.
## (Never-tuned limits live as plain consts at their use site, not here.)

import std/[os, strutils]

type
    AppConfig* = object
        # --- storage / size limits ---
        maxRequestBytes*: int64        # MAX_REQUEST_BYTES  raw request-body cap, ~51 MB (keep in sync with nginx client_max_body_size)
        inlinePasteMaxBytes*: int      # INLINE_PASTE_MAX_BYTES   256 KB
        maxStorageBytesPerIp*: int64   # MAX_STORAGE_BYTES_PER_IP 100 MB
        maxFileUploadBytes*: int64     # MAX_FILE_UPLOAD_BYTES    50 MB (single file & folder upload)

        # --- paste memory cache ---
        cacheMaxBytes*: int64          # CACHE_MAX_BYTES  128 MB (dirty pending + clean LRU combined)

        # --- global concurrency limit (the only framework rate limiter) ---
        globalConcurrency*: int        # RATE_LIMIT_GLOBAL_CONCURRENCY 30

        # --- ntfy ---
        ntfyServerUrl*: string         # NTFY_SERVER_URL   https://ntfy.sh
        ntfyTopic*: string             # NTFY_TOPIC        "" => disabled
        publicBaseUrl*: string         # PUBLIC_BASE_URL   absolute site URL (for notification links)

        # --- admin ---
        adminToken*: string            # ADMIN_TOKEN       "" => admin endpoints disabled (fail-closed)

        # --- paths / server ---
        sqlitePath*: string            # SQLITE_PATH        /data/db/pastebin.db
        blobStoragePath*: string       # BLOB_STORAGE_PATH  /data/blobs
        port*: int                     # PORT              8080
        workerThreads*: int            # WORKER_THREADS     tuned below the Pi's cores*10
        requestTimeoutMs*: int         # REQUEST_TIMEOUT_MS 30000 (recv/send idle timeout; frees a worker from a stalled client)
        networkLog*: bool              # NETWORK_LOG        default true
        accessLogPath*: string         # ACCESS_LOG_PATH        "" => disabled
        accessLogMaxBytes*: int64      # ACCESS_LOG_MAX_BYTES   5 MB (size-based rotation)
        accessLogFlushMs*: int         # ACCESS_LOG_FLUSH_MS    5000 (buffer flush interval)

proc getLong(key: string, fallback: int64): int64 =
    ## Parse an env var or fall back to a default. Base-10.
    let v = getEnv(key)
    if v.len == 0: return fallback
    try: parseBiggestInt(v.strip())
    except ValueError: fallback

proc loadConfig*(): AppConfig =
    # Raw request-body cap, rejected early on Content-Length before the body is streamed/spilled
    # (the DoS guard: an oversize upload never reaches disk). ~51 MB = MAX_FILE_UPLOAD_BYTES (50 MB)
    # plus multipart-envelope headroom, so a full 50 MB file isn't rejected by the transport layer.
    # Keep in sync with nginx client_max_body_size.
    result.maxRequestBytes         = getLong("MAX_REQUEST_BYTES", 53_477_376)  # ~51 MB
    result.inlinePasteMaxBytes     = getLong("INLINE_PASTE_MAX_BYTES", 262_144).int
    result.maxStorageBytesPerIp    = getLong("MAX_STORAGE_BYTES_PER_IP", 104_857_600)
    result.maxFileUploadBytes      = getLong("MAX_FILE_UPLOAD_BYTES", 52_428_800)   # 50 MB (single file & folder upload)
    result.globalConcurrency       = getLong("RATE_LIMIT_GLOBAL_CONCURRENCY", 30).int
    result.ntfyServerUrl           = getEnv("NTFY_SERVER_URL", "https://ntfy.sh")
    result.ntfyTopic               = getEnv("NTFY_TOPIC", "")
    result.publicBaseUrl           = getEnv("PUBLIC_BASE_URL", "https://rpi.deer-hue.ts.net")
    result.adminToken              = getEnv("ADMIN_TOKEN", "")
    result.sqlitePath              = getEnv("SQLITE_PATH", "/data/db/pastebin.db")
    result.blobStoragePath         = getEnv("BLOB_STORAGE_PATH", "/data/blobs")
    result.port                    = getLong("PORT", 8080).int
    result.workerThreads           = getLong("WORKER_THREADS", 8).int
    result.requestTimeoutMs        = getLong("REQUEST_TIMEOUT_MS", 30_000).int   # recv/send idle timeout
    result.networkLog              = getEnv("NETWORK_LOG", "true").toLowerAscii() != "false"
    result.accessLogPath           = getEnv("ACCESS_LOG_PATH", "")
    result.accessLogMaxBytes       = getLong("ACCESS_LOG_MAX_BYTES", 5_242_880)   # 5 MB
    result.accessLogFlushMs        = getLong("ACCESS_LOG_FLUSH_MS", 5_000).int    # 5 s
    result.cacheMaxBytes           = getLong("CACHE_MAX_BYTES", 134_217_728)   # 128 MB
