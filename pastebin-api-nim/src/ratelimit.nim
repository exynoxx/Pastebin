## Per-IP abuse protection: request rate limiting + overload protection, and the paste-creation
## burst/penalty guard — unified onto one lock, one per-IP table, and one idle-entry sweep.
##
## Two policies, two entry points, kept distinct because they enforce different things:
##
## 1. `tryAcquire` — runs on EVERY request (see endpoints/policies.nim), mirroring the chained
##    limiters in pastebin-api/program.cs. Three limiters apply, in order:
##      a. per-IP sliding window   (perIpPerMinute,  1 min, 6 segments)
##      b. global sliding window   (globalPerMinute, 1 min, 6 segments)
##      c. global concurrency cap  (globalConcurrency, no queue)
##    plus a stricter per-IP fixed-window "uploads" policy on the two upload routes. Any rejection
##    -> the route layer answers 503 + Retry-After: 10. On success the caller MUST release the
##    concurrency slot when the request finishes.
##
## 2. `checkPasteCreate` — runs only when creating a paste, mirroring
##    pastebin-api/services/PasteRateGuard.cs. Normal mode: up to burstLimit pastes within a rolling
##    windowSeconds; the paste that would exceed that is rejected AND trips a penalty box — for the
##    next penaltySeconds the IP is limited to one paste per penaltyIntervalSeconds. Rejection ->
##    the route layer answers 429 + Retry-After (see endpoints/context.rejectPasteLimit).
##
## Admin brute-force protection is deliberately NOT here — it counts failures, not requests, and
## escalates its own lockout; see endpoints/admin/guard.nim.
##
## Under Nim's shared-heap ORC the state Table is reachable from all worker threads, so a single
## process-wide lock guards every access.

import std/[tables, deques, locks, times]
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

    IpState = ref object
        req: SlidingState     ## per-IP request sliding window (tryAcquire)
        up: FixedState        ## per-IP uploads fixed window (tryAcquire, upload routes)
        recent: Deque[int64]  ## unix-second timestamps of allowed pastes in the burst window
        penaltyUntil: int64   ## unix second the paste penalty ends (0 = not penalized)
        lastAllowed: int64    ## unix second of the most recent allowed paste
        lastSeen: int64       ## unix second of the last touch (for stale pruning)

var
    gLock: Lock
    gIps: Table[string, IpState]
    gGlobal: SlidingState
    gConcurrent: int
    gPerIpLimit, gGlobalLimit, gConcurrencyLimit, gUploadsLimit: int
    gPasteBurstLimit, gPasteWindowSeconds, gPastePenaltySeconds, gPastePenaltyIntervalSeconds: int
    gLastSweep: int64

proc initRateLimiter*(cfg: AppConfig) =
    initLock(gLock)
    gIps = initTable[string, IpState]()
    gGlobal = SlidingState(lastSeg: 0)
    gConcurrent = 0
    gPerIpLimit       = cfg.perIpPerMinute
    gGlobalLimit      = cfg.globalPerMinute
    gConcurrencyLimit = cfg.globalConcurrency
    gUploadsLimit     = cfg.uploadsPerMinute
    gPasteBurstLimit             = max(1, cfg.pasteBurstLimit)
    gPasteWindowSeconds          = max(1, cfg.pasteBurstWindowSec)
    gPastePenaltySeconds         = max(0, cfg.pastePenaltySec)
    gPastePenaltyIntervalSeconds = max(1, cfg.pastePenaltyIntervalSec)

proc slidingTry(st: SlidingState, nowSec, limit: int64): bool =
    ## Segmented sliding-window counter. Caller holds gLock.
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
    ## Drop idle per-IP entries so the table can't grow unbounded; runs at most once per window.
    ## Keeps an IP while its paste penalty is active OR it has been seen recently by either policy.
    ## Caller holds gLock.
    if nowSec - gLastSweep < WindowSec: return
    gLastSweep = nowSec
    let idleCutoff = max(WindowSec * 2, max(gPasteWindowSeconds, gPastePenaltySeconds)).int64
    var stale: seq[string]
    for ip, st in gIps:
        if nowSec >= st.penaltyUntil and nowSec - st.lastSeen > idleCutoff:
            stale.add ip
    for ip in stale: gIps.del ip

proc ipState(ip: string, nowSec: int64): IpState =
    ## Fetch (or create) the per-IP state and stamp lastSeen. Caller holds gLock.
    if ip notin gIps:
        gIps[ip] = IpState(
            req: SlidingState(lastSeg: nowSec div SegLenSec),
            up: FixedState(),
            recent: initDeque[int64]())
    result = gIps[ip]
    result.lastSeen = nowSec

# ---- request rate limiting + overload protection ---------------------------

type AcquireResult* = object
    allowed*: bool
    concurrencyHeld*: bool

proc tryAcquire*(ip: string, isUpload: bool): AcquireResult =
    ## Applies the chained global limiters (+ uploads policy). On success the caller MUST call
    ## `releaseConcurrency` when the request finishes.
    let nowSec = getTime().toUnix()
    acquire(gLock)
    try:
        maybeSweep(nowSec)
        let st = ipState(ip, nowSec)

        if not slidingTry(st.req, nowSec, gPerIpLimit.int64):
            return AcquireResult(allowed: false, concurrencyHeld: false)

        if not slidingTry(gGlobal, nowSec, gGlobalLimit.int64):
            return AcquireResult(allowed: false, concurrencyHeld: false)

        if gConcurrent >= gConcurrencyLimit:
            return AcquireResult(allowed: false, concurrencyHeld: false)

        if isUpload and not fixedTry(st.up, nowSec, gUploadsLimit.int64):
            return AcquireResult(allowed: false, concurrencyHeld: false)

        gConcurrent.inc
        return AcquireResult(allowed: true, concurrencyHeld: true)
    finally:
        release(gLock)

proc releaseConcurrency*() =
    acquire(gLock)
    try:
        if gConcurrent > 0: gConcurrent.dec
    finally:
        release(gLock)

# ---- paste-creation burst / penalty box ------------------------------------

type Decision* = object
    allowed*: bool
    retryAfterSeconds*: int
    penalized*: bool

proc checkPasteCreate*(ip: string): Decision =
    ## The per-attempt paste-creation decision (burst window + penalty box).
    let nowSec = getTime().toUnix()
    acquire(gLock)
    try:
        maybeSweep(nowSec)
        let st = ipState(ip, nowSec)

        if nowSec < st.penaltyUntil:
            # In the penalty box: one paste per interval regardless of how long ago the burst was.
            let sinceLast = nowSec - st.lastAllowed
            if sinceLast >= gPastePenaltyIntervalSeconds:
                st.lastAllowed = nowSec
                result = Decision(allowed: true, retryAfterSeconds: 0, penalized: true)
            else:
                result = Decision(allowed: false,
                    retryAfterSeconds: int(gPastePenaltyIntervalSeconds.int64 - sinceLast), penalized: true)
        else:
            # Normal mode: drop timestamps aged out of the rolling window.
            while st.recent.len > 0 and nowSec - st.recent.peekFirst() >= gPasteWindowSeconds:
                discard st.recent.popFirst()

            if st.recent.len >= gPasteBurstLimit:
                # Over the burst limit -> trip the penalty and reject this paste.
                st.penaltyUntil = nowSec + gPastePenaltySeconds
                st.recent.clear()
                result = Decision(allowed: false, retryAfterSeconds: gPastePenaltyIntervalSeconds, penalized: true)
            else:
                st.recent.addLast(nowSec)
                st.lastAllowed = nowSec
                result = Decision(allowed: true, retryAfterSeconds: 0, penalized: false)
    finally:
        release(gLock)
