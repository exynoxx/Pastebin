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

proc segEq(path: string, a, b: int, seg: string): bool =
    ## path[a ..< b] == seg, compared in place (no slice allocation).
    if b - a != seg.len: return false
    for i in 0 ..< seg.len:
        if path[a + i] != seg[i]: return false
    true

proc tryMatch[P](route: Route[P], path: string, lo, hi: int,
                 params: var seq[string]): bool =
    ## Walk the '/'-delimited segments of path[lo ..< hi] against route.segments, with the same
    ## semantics as splitPath (leading/trailing '/' already stripped into lo/hi; interior empty
    ## segments preserved; an empty range is one empty segment). Fills `params` for {param} slots.
    params.setLen(0)
    var idx = 0
    var start = lo
    let n = route.segments.len
    while true:
        var segEnd = start
        while segEnd < hi and path[segEnd] != '/': inc segEnd
        if idx >= n: return false                       # more path segments than the route has
        if isParam(route.segments[idx]):
            params.add path[start ..< segEnd]
        elif not segEq(path, start, segEnd, route.segments[idx]):
            return false
        inc idx
        if segEnd >= hi: break
        start = segEnd + 1
    idx == n                                            # fewer path segments than the route => no

proc match*[P](r: Router[P], verb, path: string):
        tuple[found: bool, payload: P, params: seq[string]] =
    ## Match a raw request path without splitting it into a seq first. Literal routes win over
    ## `{param}` routes, so a fixed path like /api/files/upload is never swallowed by
    ## /api/files/{id}. Pass 1: exact (paramless) routes; pass 2: param routes.
    var lo = 0
    var hi = path.len
    while lo < hi and path[lo] == '/': inc lo
    while hi > lo and path[hi - 1] == '/': dec hi
    var params: seq[string]
    for route in r.routes:
        if route.verb == verb and not route.hasParams and tryMatch(route, path, lo, hi, params):
            return (true, route.payload, params)
    for route in r.routes:
        if route.verb == verb and route.hasParams and tryMatch(route, path, lo, hi, params):
            return (true, route.payload, params)
    (false, default(P), @[])
