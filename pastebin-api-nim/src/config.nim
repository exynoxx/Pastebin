## Typed application configuration, sourced from environment variables.
##
## Mirrors pastebin-api/models/AppLimits.cs and the env-var overrides read in
## pastebin-api/program.cs. Every default here is byte-identical to the .NET default so
## the Nim backend behaves the same when no env vars are set.

import std/[os, strutils]

type
    AppConfig* = object
        # --- storage / size limits (AppLimits.cs) ---
        maxRequestBytes*: int64        # MAX_REQUEST_BYTES        1 GB
        inlinePasteMaxBytes*: int      # INLINE_PASTE_MAX_BYTES   256 KB
        pastePreviewChars*: int        # PASTE_PREVIEW_CHARS      8192
        maxPasteBytes*: int64          # MAX_PASTE_BYTES          10 MB
        maxStorageBytesPerIp*: int64   # MAX_STORAGE_BYTES_PER_IP 100 MB
        untitledTitleMaxChars*: int    # UNTITLED_TITLE_MAX_CHARS 40

        # --- framework rate limits (program.cs) ---
        perIpPerMinute*: int           # RATE_LIMIT_PER_IP_PER_MIN     120
        uploadsPerMinute*: int         # RATE_LIMIT_UPLOADS_PER_MIN    10
        globalConcurrency*: int        # RATE_LIMIT_GLOBAL_CONCURRENCY 50
        globalPerMinute*: int          # RATE_LIMIT_GLOBAL_PER_MIN     600

        # --- paste burst / penalty box (PasteRateGuard) ---
        pasteBurstLimit*: int          # PASTE_BURST_LIMIT          10
        pasteBurstWindowSec*: int      # PASTE_BURST_WINDOW_SEC     60
        pastePenaltySec*: int          # PASTE_PENALTY_SEC          1800
        pastePenaltyIntervalSec*: int  # PASTE_PENALTY_INTERVAL_SEC 60

        # --- ntfy (NtfyNotifier) ---
        ntfyServerUrl*: string         # NTFY_SERVER_URL   https://ntfy.sh
        ntfyTopic*: string             # NTFY_TOPIC        "" => disabled
        publicBaseUrl*: string         # PUBLIC_BASE_URL   "" => links relative/incomplete

        # --- admin ---
        adminToken*: string            # ADMIN_TOKEN       "" => admin endpoints disabled (fail-closed)

        # --- paths / server ---
        sqlitePath*: string            # SQLITE_PATH        /data/db/pastebin.db
        blobStoragePath*: string       # BLOB_STORAGE_PATH  /data/blobs
        port*: int                     # PORT              8080
        workerThreads*: int            # WORKER_THREADS     tuned below the Pi's cores*10
        networkLog*: bool              # NETWORK_LOG        default true

proc getLong(key: string, fallback: int64): int64 =
    ## Mirrors program.cs GetLong: parse or fall back. Invariant/base-10.
    let v = getEnv(key)
    if v.len == 0: return fallback
    try: parseBiggestInt(v.strip())
    except ValueError: fallback

proc getInt(key: string, fallback: int): int =
    int(getLong(key, fallback.int64))

proc loadConfig*(): AppConfig =
    result.maxRequestBytes       = getLong("MAX_REQUEST_BYTES", 1_073_741_824)
    result.inlinePasteMaxBytes   = getInt("INLINE_PASTE_MAX_BYTES", 262_144)
    result.pastePreviewChars     = getInt("PASTE_PREVIEW_CHARS", 8_192)
    result.maxPasteBytes         = getLong("MAX_PASTE_BYTES", 10_485_760)
    result.maxStorageBytesPerIp  = getLong("MAX_STORAGE_BYTES_PER_IP", 104_857_600)
    result.untitledTitleMaxChars = getInt("UNTITLED_TITLE_MAX_CHARS", 40)

    result.perIpPerMinute        = getInt("RATE_LIMIT_PER_IP_PER_MIN", 120)
    result.uploadsPerMinute      = getInt("RATE_LIMIT_UPLOADS_PER_MIN", 10)
    result.globalConcurrency     = getInt("RATE_LIMIT_GLOBAL_CONCURRENCY", 50)
    result.globalPerMinute       = getInt("RATE_LIMIT_GLOBAL_PER_MIN", 600)

    result.pasteBurstLimit       = getInt("PASTE_BURST_LIMIT", 10)
    result.pasteBurstWindowSec   = getInt("PASTE_BURST_WINDOW_SEC", 60)
    result.pastePenaltySec       = getInt("PASTE_PENALTY_SEC", 1800)
    result.pastePenaltyIntervalSec = getInt("PASTE_PENALTY_INTERVAL_SEC", 60)

    result.ntfyServerUrl = getEnv("NTFY_SERVER_URL", "https://ntfy.sh")
    result.ntfyTopic     = getEnv("NTFY_TOPIC", "")
    result.publicBaseUrl = getEnv("PUBLIC_BASE_URL", "")

    result.adminToken      = getEnv("ADMIN_TOKEN", "")

    result.sqlitePath      = getEnv("SQLITE_PATH", "/data/db/pastebin.db")
    result.blobStoragePath = getEnv("BLOB_STORAGE_PATH", "/data/blobs")
    result.port          = getInt("PORT", 8080)
    # Mummy's default worker pool is cores*10; the Pi 3B has 4 cores, so 40 threads each
    # with a stack would blow the 250 MB cap. Pin low (plan suggests 8).
    result.workerThreads = getInt("WORKER_THREADS", 8)
    result.networkLog    = getEnv("NETWORK_LOG", "true").toLowerAscii() != "false"
