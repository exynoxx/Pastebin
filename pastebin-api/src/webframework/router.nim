## Generic URL router: literal + `{param}` path matching over an app-supplied payload type.
##
## App-agnostic — the router maps a (verb, path) to a payload `P` plus the captured path
## parameters; it knows nothing about handlers, auth, or rate limits. The app defines `P` (e.g. a
## handler paired with per-route policy flags) and acts on the match. Runs on the server workers.

import std/strutils

type
    Route[P] = object
        verb: string            ## "GET" | "POST" | "DELETE"
        segments: seq[string]   ## split pattern; a "{name}" segment matches any single segment
        hasParams: bool         ## true if any segment is a "{param}" (cached for matching)
        payload: P              ## app-supplied route payload (handler + policy)

    Router*[P] = object
        routes: seq[Route[P]]

proc splitPath*(p: string): seq[string] =
    p.strip(chars = {'/'}).split('/')

proc isParam(seg: string): bool =
    seg.len >= 2 and seg[0] == '{' and seg.endsWith('}')

proc add*[P](r: var Router[P], verb, pattern: string, payload: P) =
    ## Register a route. Call at startup, before the workers start.
    let segs = splitPath(pattern)
    var hasParams = false
    for s in segs:
        if isParam(s): hasParams = true
    r.routes.add Route[P](verb: verb, segments: segs, hasParams: hasParams, payload: payload)

proc tryMatch[P](route: Route[P], segs: seq[string], params: var seq[string]): bool =
    if route.segments.len != segs.len: return false
    params.setLen(0)
    for i in 0 ..< segs.len:
        if isParam(route.segments[i]):
            params.add segs[i]
        elif route.segments[i] != segs[i]:
            return false
    true

proc match*[P](r: Router[P], verb: string, segs: seq[string]):
        tuple[found: bool, payload: P, params: seq[string]] =
    ## Literal routes win over `{param}` routes, so a fixed path like /api/files/upload is never
    ## swallowed by /api/files/{id}. Pass 1: exact (paramless) routes; pass 2: param routes.
    var params: seq[string]
    for route in r.routes:
        if route.verb == verb and not route.hasParams and tryMatch(route, segs, params):
            return (true, route.payload, params)
    for route in r.routes:
        if route.verb == verb and route.hasParams and tryMatch(route, segs, params):
            return (true, route.payload, params)
    (false, default(P), @[])
