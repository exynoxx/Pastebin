## The router: URL-pattern matching + the cross-cutting middleware that wraps every request
## (3-tier rate limiter, admin token gate). The endpoint *table* lives in routes.nim; this module
## just turns a matched route into a handler call. Runs on the httpserver worker threads.

import std/[strutils, os]
import ../httpserver, ../config, ../clientip, ../jsonbuild, ../ratelimit, ../adminguard
import context

type
    Route = object
        verb: string              ## "GET" | "POST" | "DELETE"
        segments: seq[string]     ## split pattern; a "{name}" segment matches any single segment
        hasParams: bool           ## true if any segment is a "{param}" (cached for matching)
        handler: EndpointHandler
        admin: bool               ## require a valid X-Admin-Token (fail-closed + lockout)
        upload: bool              ## use the dedicated uploads rate-limit policy

    Router* = object
        routes: seq[Route]

const BusyBody = errorJson("Server busy or rate limit exceeded. Please retry shortly.")

var gRoutes: Router   ## built once at startup (initRoutes), only read on the worker threads.

# ---- registration DSL (used by routes.nim) ---------------------------------

proc splitPath(p: string): seq[string] =
    p.strip(chars = {'/'}).split('/')

proc isParam(seg: string): bool =
    seg.len >= 2 and seg[0] == '{' and seg[^1] == '}'

proc add(r: var Router, verb, pattern: string, handler: EndpointHandler,
         admin, upload: bool) =
    let segs = splitPath(pattern)
    var hasParams = false
    for s in segs:
        if isParam(s): hasParams = true
    r.routes.add Route(verb: verb, segments: segs, hasParams: hasParams,
                       handler: handler, admin: admin, upload: upload)

proc get*(r: var Router, pattern: string, handler: EndpointHandler,
          admin = false) =
    r.add("GET", pattern, handler, admin, upload = false)

proc post*(r: var Router, pattern: string, handler: EndpointHandler,
           admin = false, upload = false) =
    r.add("POST", pattern, handler, admin, upload)

proc delete*(r: var Router, pattern: string, handler: EndpointHandler,
             admin = false) =
    r.add("DELETE", pattern, handler, admin, upload = false)

proc initRoutes*(r: Router) =
    ## Install the route table. Call once at startup, before the server threads start.
    gRoutes = r

# ---- matching --------------------------------------------------------------

proc tryMatch(route: Route, segs: seq[string], params: var seq[string]): bool =
    if route.segments.len != segs.len: return false
    params.setLen(0)
    for i in 0 ..< segs.len:
        if isParam(route.segments[i]):
            params.add segs[i]
        elif route.segments[i] != segs[i]:
            return false
    true

proc matchRoute(verb: string, segs: seq[string]):
        tuple[found: bool, route: Route, params: seq[string]] =
    ## Literal routes win over `{param}` routes, so a fixed path like /api/files/upload is never
    ## swallowed by /api/files/{id}. Pass 1: exact (paramless) routes; pass 2: param routes.
    var params: seq[string]
    for route in gRoutes.routes:
        if route.verb == verb and not route.hasParams and tryMatch(route, segs, params):
            return (true, route, params)
    for route in gRoutes.routes:
        if route.verb == verb and route.hasParams and tryMatch(route, segs, params):
            return (true, route, params)
    (false, Route(), @[])

# ---- middleware ------------------------------------------------------------

proc passAdminGate(cfg: AppConfig, req: Request, ip: string): bool =
    ## Fail-closed admin auth: an unset ADMIN_TOKEN (or a mismatch) rejects with 401. The token is
    ## short, so adminguard makes guessing expensive — an escalating per-IP lockout (instant 429
    ## while cooling down) plus a fixed delay + constant-time compare on each failed attempt.
    ## Responds and returns false on rejection; returns true when the caller may proceed.
    let gate = adminPrecheck(ip)
    if gate.lockedOut:
        req.respond(429, errorJson("Too many failed admin attempts. Try again later."),
            extraHeaders = [("Retry-After", $gate.retryAfterSeconds)])
        return false
    if cfg.adminToken.len == 0 or not constantTimeEq(req.header("X-Admin-Token"), cfg.adminToken):
        registerAdminFailure(ip)
        sleep(AdminFailPenaltyMs)
        req.respond(401, errorJson("Unauthorized"))
        return false
    clearAdminFailures(ip)
    true

# ---- entry point -----------------------------------------------------------

proc route*(cfg: AppConfig, req: Request) =
    ## Top-level per-request entry (called by the server's handler). Applies the 3-tier framework
    ## limiter — uploads get the dedicated policy — then the admin gate, then the endpoint.
    let ip = resolveClientIp(req)
    let m = matchRoute(req.httpMethod, splitPath(req.path))

    let acq = tryAcquire(ip, isUpload = m.found and m.route.upload)
    if not acq.allowed:
        req.respond(503, BusyBody, extraHeaders = [("Retry-After", "10")])
        return
    try:
        if not m.found:
            respondError(req, 404, "Not found")
            return
        if m.route.admin and not passAdminGate(cfg, req, ip):
            return
        m.route.handler(Ctx(cfg: cfg, req: req, ip: ip, params: m.params))
    finally:
        if acq.concurrencyHeld: releaseConcurrency()
