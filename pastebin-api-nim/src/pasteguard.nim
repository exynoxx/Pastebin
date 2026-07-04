## Per-IP paste-creation abuse guard with a "penalty box", mirroring
## pastebin-api/services/PasteRateGuard.cs.
##
## Normal mode: up to burstLimit pastes within a rolling windowSeconds. The paste that would
## exceed that is rejected AND trips the penalty: for the next penaltySeconds the IP is limited
## to one paste per penaltyIntervalSeconds. Answers with 429 + Retry-After (see routes).
##
## Under Nim's shared-heap ORC the state Table is reachable from all Mummy worker threads, so a
## single process-wide lock guards every access (the .NET version locks per-IpState).

import std/[tables, deques, locks, times, math]
import config

type
    Decision* = object
        allowed*: bool
        retryAfterSeconds*: int
        penalized*: bool

    IpState = ref object
        recent: Deque[int64]  ## unix-second timestamps of allowed pastes in the window
        penaltyUntil: int64   ## unix second the penalty ends (0 = not penalized)
        lastAllowed: int64    ## unix second of the most recent allowed paste
        lastSeen: int64       ## unix second of the last check (for stale pruning)

var
    gStates: Table[string, IpState]
    gLock: Lock
    gBurstLimit, gWindowSeconds, gPenaltySeconds, gPenaltyIntervalSeconds: int
    gLastSweep: int64

proc initPasteGuard*(cfg: AppConfig) =
    initLock(gLock)
    gStates = initTable[string, IpState]()
    gBurstLimit            = max(1, cfg.pasteBurstLimit)
    gWindowSeconds         = max(1, cfg.pasteBurstWindowSec)
    gPenaltySeconds        = max(0, cfg.pastePenaltySec)
    gPenaltyIntervalSeconds = max(1, cfg.pastePenaltyIntervalSec)

proc maybeSweep(nowSec: int64) =
    ## Opportunistic cleanup; runs at most once per window. Caller holds gLock.
    if nowSec - gLastSweep < gWindowSeconds: return
    gLastSweep = nowSec
    let idleCutoff = max(gWindowSeconds, gPenaltySeconds)
    var stale: seq[string]
    for ip, st in gStates:
        if nowSec >= st.penaltyUntil and nowSec - st.lastSeen > idleCutoff:
            stale.add ip
    for ip in stale: gStates.del ip

proc check*(ip: string): Decision =
    let nowSec = getTime().toUnix()
    acquire(gLock)
    try:
        if ip notin gStates:
            gStates[ip] = IpState(recent: initDeque[int64]())
        let st = gStates[ip]
        st.lastSeen = nowSec

        if nowSec < st.penaltyUntil:
            # In the penalty box: one paste per interval regardless of how long ago the burst was.
            let sinceLast = nowSec - st.lastAllowed
            if sinceLast >= gPenaltyIntervalSeconds:
                st.lastAllowed = nowSec
                result = Decision(allowed: true, retryAfterSeconds: 0, penalized: true)
            else:
                result = Decision(allowed: false,
                    retryAfterSeconds: int(gPenaltyIntervalSeconds.int64 - sinceLast), penalized: true)
        else:
            # Normal mode: drop timestamps aged out of the rolling window.
            while st.recent.len > 0 and nowSec - st.recent.peekFirst() >= gWindowSeconds:
                discard st.recent.popFirst()

            if st.recent.len >= gBurstLimit:
                # Over the burst limit -> trip the penalty and reject this paste.
                st.penaltyUntil = nowSec + gPenaltySeconds
                st.recent.clear()
                result = Decision(allowed: false, retryAfterSeconds: gPenaltyIntervalSeconds, penalized: true)
            else:
                st.recent.addLast(nowSec)
                st.lastAllowed = nowSec
                result = Decision(allowed: true, retryAfterSeconds: 0, penalized: false)

        maybeSweep(nowSec)
    finally:
        release(gLock)
