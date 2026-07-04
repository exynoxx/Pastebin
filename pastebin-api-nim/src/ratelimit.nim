## Framework rate limiting + overload protection, mirroring the chained limiters in
## pastebin-api/program.cs. Three limiters apply to every request, in order:
##   1. per-IP sliding window   (perIpPerMinute,  1 min, 6 segments)
##   2. global sliding window   (globalPerMinute, 1 min, 6 segments)
##   3. global concurrency cap  (globalConcurrency, no queue)
## A stricter per-IP fixed-window "uploads" policy is layered on the two upload routes.
## Any rejection -> the route layer answers 503 + Retry-After: 10 + the busy JSON.

import std/[tables, locks, times, math]
import config

const
    Segments = 6
    WindowSec = 60
    SegLenSec = WindowSec div Segments   # 10s

type
    SlidingState = ref object
        counts: array[Segments, int]
        lastSeg: int64
    FixedState = ref object
        windowStart: int64
        count: int

var
    gRlLock: Lock
    gPerIp: Table[string, SlidingState]
    gGlobal: SlidingState
    gUploads: Table[string, FixedState]
    gConcurrent: int
    gPerIpLimit, gGlobalLimit, gConcurrencyLimit, gUploadsLimit: int
    gLastSweep: int64

proc initRateLimiter*(cfg: AppConfig) =
    initLock(gRlLock)
    gPerIp = initTable[string, SlidingState]()
    gUploads = initTable[string, FixedState]()
    gGlobal = SlidingState(lastSeg: 0)
    gPerIpLimit       = cfg.perIpPerMinute
    gGlobalLimit      = cfg.globalPerMinute
    gConcurrencyLimit = cfg.globalConcurrency
    gUploadsLimit     = cfg.uploadsPerMinute
    gConcurrent = 0

proc slidingTry(st: SlidingState, nowSec, limit: int64): bool =
    ## Segmented sliding-window counter. Caller holds gRlLock.
    let seg = nowSec div SegLenSec
    if seg != st.lastSeg:
        let diff = seg - st.lastSeg
        if diff >= Segments:
            for i in 0 ..< Segments: st.counts[i] = 0
        else:
            # Clear the segments that have just rotated into the window.
            for d in 1 .. diff:
                st.counts[int((st.lastSeg + d) mod Segments)] = 0
        st.lastSeg = seg
    var total = 0
    for c in st.counts: total += c
    if total.int64 >= limit: return false
    st.counts[int(seg mod Segments)].inc
    true

proc fixedTry(st: FixedState, nowSec, limit: int64): bool =
    let winStart = (nowSec div WindowSec) * WindowSec
    if st.windowStart != winStart:
        st.windowStart = winStart
        st.count = 0
    if st.count.int64 >= limit: return false
    st.count.inc
    true

proc maybeSweep(nowSec: int64) =
    ## Drop idle per-IP entries so the tables can't grow unbounded. Caller holds gRlLock.
    if nowSec - gLastSweep < WindowSec: return
    gLastSweep = nowSec
    var staleIp: seq[string]
    for ip, st in gPerIp:
        if nowSec - (st.lastSeg * SegLenSec) > WindowSec * 2: staleIp.add ip
    for ip in staleIp: gPerIp.del ip
    var staleUp: seq[string]
    for ip, st in gUploads:
        if nowSec - st.windowStart > WindowSec * 2: staleUp.add ip
    for ip in staleUp: gUploads.del ip

type AcquireResult* = object
    allowed*: bool
    concurrencyHeld*: bool

proc tryAcquire*(ip: string, isUpload: bool): AcquireResult =
    ## Applies the chained global limiters (+ uploads policy). On success the caller MUST call
    ## `releaseConcurrency` when the request finishes.
    let nowSec = getTime().toUnix()
    acquire(gRlLock)
    try:
        maybeSweep(nowSec)

        if ip notin gPerIp: gPerIp[ip] = SlidingState(lastSeg: nowSec div SegLenSec)
        if not slidingTry(gPerIp[ip], nowSec, gPerIpLimit.int64):
            return AcquireResult(allowed: false, concurrencyHeld: false)

        if not slidingTry(gGlobal, nowSec, gGlobalLimit.int64):
            return AcquireResult(allowed: false, concurrencyHeld: false)

        if gConcurrent >= gConcurrencyLimit:
            return AcquireResult(allowed: false, concurrencyHeld: false)

        if isUpload:
            if ip notin gUploads: gUploads[ip] = FixedState(windowStart: 0, count: 0)
            if not fixedTry(gUploads[ip], nowSec, gUploadsLimit.int64):
                return AcquireResult(allowed: false, concurrencyHeld: false)

        gConcurrent.inc
        return AcquireResult(allowed: true, concurrencyHeld: true)
    finally:
        release(gRlLock)

proc releaseConcurrency*() =
    acquire(gRlLock)
    try:
        if gConcurrent > 0: gConcurrent.dec
    finally:
        release(gRlLock)
