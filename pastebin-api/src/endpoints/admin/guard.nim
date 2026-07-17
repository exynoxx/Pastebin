## Admin-API auth for the admin slice. A short admin token is only safe if guessing is made
## expensive, so `requireAdmin` defends every X-Admin-Token check with an escalating per-IP
## lockout: the FIRST failed attempt already locks the IP for BaseCooldownSec, and each further
## failure doubles the cooldown (2s, 4s, 8s, … capped at 5 min). While an IP is in its cooldown,
## attempts are rejected INSTANTLY with 429 + Retry-After — no worker thread is held.
##
## The lockout deliberately does NO blocking sleep on the failing request. An earlier version
## slept AdminFailPenaltyMs on the worker thread on every failure; because an IP's *first* attempt
## isn't yet locked out, an attacker spraying wrong tokens from many IPs could tie up the whole
## small worker pool one 500 ms sleep at a time — the very pool-exhaustion the lockout exists to
## prevent. The lockout (first failure ⇒ immediate cooldown) rate-limits guesses without holding a
## thread, and constantTimeEq keeps the comparison itself timing-safe.
##
## A successful auth clears the IP's counter. Mirrors ratelimit.nim's locking model: one
## process-wide lock guards the state Table, which is shared across all worker threads under ORC.
##
## `requireAdmin` is a fail-closed upfront guard, not middleware: the check is a pure precondition
## with no on-the-way-out work, so admin handlers call it as their first line — mirroring
## ratelimit.rejectPasteLimit — rather than wrapping the request in the middleware chain.

import std/[tables, locks, times]
import ../routes
import ../../macros

const
    BaseCooldownSec* = 2        ## first failed attempt locks the IP for this long
    MaxCooldownSec*  = 300      ## cap on the doubling cooldown (5 minutes)

type
    AdminGate = object
        lockedOut: bool         ## true => reject immediately, don't even check the token
        retryAfterSeconds: int  ## seconds until the next attempt is allowed (when lockedOut)

    IpFail = ref object
        fails: int
        lockedUntil: int64       ## unix second before which attempts are refused
        lastSeen: int64

var
    gFails: Table[string, IpFail]
    gLock: Lock
    gLastSweep: int64

proc initAdminGuard*() =
    initLock(gLock)
    gFails = initTable[string, IpFail]()

proc sweep(nowSec: int64) =
    ## Drop entries whose cooldown expired and that have been idle a while. Caller holds gLock.
    returnif(nowSec - gLastSweep < MaxCooldownSec)
    gLastSweep = nowSec
    var stale: seq[string]
    for ip, st in gFails:
        if nowSec >= st.lockedUntil and nowSec - st.lastSeen > MaxCooldownSec:
            stale.add ip
    for ip in stale: gFails.del ip

proc adminPrecheck(ip: string): AdminGate =
    ## Call BEFORE validating the token. Returns lockedOut when the IP is inside its cooldown.
    let nowSec = getTime().toUnix()
    withLock gLock:
        sweep(nowSec)
        if ip in gFails:
            let st = gFails[ip]
            st.lastSeen = nowSec
            if nowSec < st.lockedUntil:
                result = AdminGate(lockedOut: true, retryAfterSeconds: int(st.lockedUntil - nowSec))

proc registerAdminFailure(ip: string) =
    ## Record a failed attempt and escalate the cooldown (doubling, capped at MaxCooldownSec).
    let nowSec = getTime().toUnix()
    withLock gLock:
        if ip notin gFails:
            gFails[ip] = IpFail()
        let st = gFails[ip]
        st.fails.inc
        st.lastSeen = nowSec
        var cd = BaseCooldownSec
        for _ in 2 .. st.fails:
            cd = min(cd * 2, MaxCooldownSec)
        st.lockedUntil = nowSec + cd

proc clearAdminFailures(ip: string) =
    ## Reset an IP's counter after a successful auth.
    withLock gLock:
        gFails.del ip

func constantTimeEq(a, b: string): bool =
    ## Length-checked constant-time compare: no early-out on the first differing byte, so a
    ## correct-prefix guess can't be distinguished from a wrong one by response timing.
    returnif(a.len != b.len, false)
    var diff = 0
    for i in 0 ..< a.len:
        diff = diff or (ord(a[i]) xor ord(b[i]))
    diff == 0

proc requireAdmin*(ctx: Ctx): bool =
    ## Fail-closed admin auth, called as the first line of every admin handler. Returns true when
    ## the caller holds a valid X-Admin-Token. On failure it has already responded — 429 while the
    ## IP is locked out, else 401 (and a recorded failure that arms the cooldown) — so the handler
    ## just `return`s. An unset ADMIN_TOKEN rejects everything (fail-closed).
    let gate = adminPrecheck(ctx.ip)
    if gate.lockedOut:
        ctx.req.respond(429, errorJson("Too many failed admin attempts. Try again later."),
            extraHeaders = [("Retry-After", $gate.retryAfterSeconds)])
        return false
    if ctx.cfg.adminToken.len == 0 or
       not constantTimeEq(ctx.req.header("X-Admin-Token"), ctx.cfg.adminToken):
        registerAdminFailure(ctx.ip)
        ctx.req.respond(401, errorJson("Unauthorized"))
        return false
    clearAdminFailures(ctx.ip)
    true
