## Typed application configuration, sourced from environment variables.
##
## A few limits that nobody tunes in practice are fixed constants rather than env vars
## (see loadConfig); the rest fall back to sensible defaults when their env var is unset.

import std/[os, strutils]

type
    AppConfig* = object
        # --- storage / size limits ---
        maxRequestBytes*: int64        # fixed 1 GB (keep in sync with nginx client_max_body_size)
        inlinePasteMaxBytes*: int      # INLINE_PASTE_MAX_BYTES   256 KB
        pastePreviewChars*: int        # fixed 8192
        maxPasteBytes*: int64          # MAX_PASTE_BYTES          10 MB
        maxStorageBytesPerIp*: int64   # MAX_STORAGE_BYTES_PER_IP 100 MB
        maxFileUploadBytes*: int64     # MAX_FILE_UPLOAD_BYTES    50 MB (single file & folder upload)
        untitledTitleMaxChars*: int    # fixed 40

        # --- framework rate limits ---
        perIpPerMinute*: int           # RATE_LIMIT_PER_IP_PER_MIN     120
        uploadsPerMinute*: int         # RATE_LIMIT_UPLOADS_PER_MIN    10
        globalConcurrency*: int        # RATE_LIMIT_GLOBAL_CONCURRENCY 50
        globalPerMinute*: int          # RATE_LIMIT_GLOBAL_PER_MIN     600

        # --- paste burst / penalty box ---
        pasteBurstLimit*: int          # PASTE_BURST_LIMIT          10
        pasteBurstWindowSec*: int      # PASTE_BURST_WINDOW_SEC     60
        pastePenaltySec*: int          # PASTE_PENALTY_SEC          1800
        pastePenaltyIntervalSec*: int  # PASTE_PENALTY_INTERVAL_SEC 60

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
        networkLog*: bool              # NETWORK_LOG        default true

proc getLong(key: string, fallback: int64): int64 =
    ## Parse an env var or fall back to a default. Base-10.
    let v = getEnv(key)
    if v.len == 0: return fallback
    try: parseBiggestInt(v.strip())
    except ValueError: fallback

proc loadConfig*(): AppConfig =
    result.maxRequestBytes         = 1_073_741_824    # 1 GB
    result.pastePreviewChars       = 8_192
    result.untitledTitleMaxChars   = 40
    result.inlinePasteMaxBytes     = getLong("INLINE_PASTE_MAX_BYTES", 262_144).int
    result.maxPasteBytes           = getLong("MAX_PASTE_BYTES", 10_485_760)
    result.maxStorageBytesPerIp    = getLong("MAX_STORAGE_BYTES_PER_IP", 104_857_600)
    result.maxFileUploadBytes      = getLong("MAX_FILE_UPLOAD_BYTES", 52_428_800)   # 50 MB (single file & folder upload)
    result.perIpPerMinute          = getLong("RATE_LIMIT_PER_IP_PER_MIN", 120).int
    result.uploadsPerMinute        = getLong("RATE_LIMIT_UPLOADS_PER_MIN", 10).int
    result.globalConcurrency       = getLong("RATE_LIMIT_GLOBAL_CONCURRENCY", 50).int
    result.globalPerMinute         = getLong("RATE_LIMIT_GLOBAL_PER_MIN", 600).int
    result.pasteBurstLimit         = getLong("PASTE_BURST_LIMIT", 10).int
    result.pasteBurstWindowSec     = getLong("PASTE_BURST_WINDOW_SEC", 60).int
    result.pastePenaltySec         = getLong("PASTE_PENALTY_SEC", 1800).int
    result.pastePenaltyIntervalSec = getLong("PASTE_PENALTY_INTERVAL_SEC", 60).int
    result.ntfyServerUrl           = getEnv("NTFY_SERVER_URL", "https://ntfy.sh")
    result.ntfyTopic               = getEnv("NTFY_TOPIC", "")
    result.publicBaseUrl           = getEnv("PUBLIC_BASE_URL", "https://rpi.deer-hue.ts.net")
    result.adminToken              = getEnv("ADMIN_TOKEN", "")
    result.sqlitePath              = getEnv("SQLITE_PATH", "/data/db/pastebin.db")
    result.blobStoragePath         = getEnv("BLOB_STORAGE_PATH", "/data/blobs")
    result.port                    = getLong("PORT", 8080).int
    result.workerThreads           = getLong("WORKER_THREADS", 8).int
    result.networkLog              = getEnv("NETWORK_LOG", "true").toLowerAscii() != "false"
