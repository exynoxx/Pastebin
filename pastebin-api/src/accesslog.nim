## Access log: one plaintext line per request — `timestamp ip method path`.
##
## Registered as the OUTERMOST global middleware (before rate limiting — see endpoints/routes.nim),
## so it records EVERY access, including requests the rate limiter sheds (503) or that 404. It logs
## on the way in (before `next()`), so a downstream short-circuit still leaves a record.
##
## Lines are accumulated in an in-memory buffer and flushed to disk periodically by a background
## thread (every `flushMs`), rather than one write+fsync per request — the log stays cheap under load
## and the file is still retrievable within a few seconds. Trade-off: on a hard crash the last
## sub-`flushMs` window of lines (bounded by the rate limits, so tiny) may not reach disk.
##
## Rotation is size-based with EVER-INCREASING numbers: the active file is `<path>` (e.g.
## `access.log`); when it reaches `maxBytes` it is renamed to `<path>.<n>` with `n` only ever climbing
## (newest rotated = highest number), and a fresh active file is opened. Existing rotated files are
## never renamed. Age-based cleanup is deliberately NOT here — a cron on the Pi prunes `<path>.*` older
## than ~2 weeks; the active (unnumbered) file never matches that glob. Empty path => disabled (no-op).
##
## Under Nim's shared-heap ORC the buffer + file handle are reachable from all worker threads and the
## flusher thread, so a single process-wide lock guards every access (mirrors ratelimit.nim's gLock).

import std/[os, locks, strutils]
import config, timeutil
import webframework/[context, middleware]

var
    gLock: Lock
    gFile: File
    gEnabled: bool
    gPath: string
    gMaxBytes: int64
    gCurBytes: int64        ## bytes in the active file, tracked to avoid a stat() per flush
    gNextSeq: int           ## next rotation suffix; ever-increasing, seeded from disk at startup
    gBuf: string            ## unflushed lines, each terminated by '\n'
    gFlushMs: int
    gFlusher: Thread[void]

# Bodies live at the bottom so the public API reads first; Nim needs them declared before use.
proc flushBuffer()
proc rotate()
proc scanNextSeq(path: string): int
proc flushLoop() {.thread.}

# ---- public API ------------------------------------------------------------

proc initAccessLog*(cfg: AppConfig) =
    ## Open the active log for appending, seed the rotation counter, and start the periodic flusher.
    ## No-op when disabled.
    gEnabled = cfg.accessLogPath.len > 0
    if not gEnabled: return
    gPath = cfg.accessLogPath
    gMaxBytes = cfg.accessLogMaxBytes
    gFlushMs = max(1, cfg.accessLogFlushMs)
    let dir = parentDir(gPath)
    if dir.len > 0: createDir(dir)
    gFile = open(gPath, fmAppend)
    gCurBytes = getFileSize(gPath)
    gNextSeq = scanNextSeq(gPath)
    gBuf = newStringOfCap(64 * 1024)
    initLock(gLock)
    createThread(gFlusher, flushLoop)

proc accessLog*(): Middleware[AppConfig] =
    ## Request middleware: append `timestamp ip method path` to the in-memory buffer, then proceed.
    ## The background flusher writes it to disk (see flushLoop).
    result = proc(ctx: Ctx[AppConfig], next: Next) {.gcsafe.} =
        {.cast(gcsafe).}:
            if gEnabled:
                let line = formatMillisUtc(nowMillis()) & " " & ctx.ip & " " &
                    ctx.httpMethod & " " & ctx.path
                withLock gLock:
                    gBuf.add line
                    gBuf.add '\n'
            next()

# ---- private helpers -------------------------------------------------------

proc flushLoop() {.thread.} =
    ## Background thread: every gFlushMs, drain the buffer to disk. Runs for the life of the process.
    {.cast(gcsafe).}:
        while true:
            sleep(gFlushMs)
            withLock gLock:
                flushBuffer()

proc flushBuffer() =
    ## Called under gLock. Write and fsync the accumulated lines, then rotate if the file is full.
    if gBuf.len == 0: return
    gFile.write(gBuf)
    gFile.flushFile()
    gCurBytes += gBuf.len
    gBuf.setLen(0)
    if gCurBytes >= gMaxBytes: rotate()

proc rotate() =
    ## Called under gLock (after a flush). Retire the active file to the next ever-increasing suffix,
    ## then reopen a fresh (empty) active file. The active file stays unnumbered so the retention cron
    ## never hits it.
    gFile.close()
    moveFile(gPath, gPath & "." & $gNextSeq)
    inc gNextSeq
    gFile = open(gPath, fmAppend)
    gCurBytes = 0

proc scanNextSeq(path: string): int =
    ## Highest existing `<path>.<n>` + 1, so numbering keeps climbing across restarts (>= 1).
    let dir = parentDir(path)
    let prefix = extractFilename(path) & "."
    var maxSeq = 0
    for _, entry in walkDir(if dir.len > 0: dir else: "."):
        let name = extractFilename(entry)
        if name.startsWith(prefix):
            try:
                let n = parseInt(name[prefix.len .. ^1])
                if n > maxSeq: maxSeq = n
            except ValueError: discard   # not a numbered rotation (e.g. access.log.gz) — ignore
    maxSeq + 1
