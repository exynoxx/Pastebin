## GET /api/admin/access-log — most recent access-log lines, newest first (admin only).

import std/[json, strutils]
import ../routes, guard
referencing accesslog

const
    DefaultLimit = 200
    MaxLimit = 1000

proc handleAdminAccessLog*(ctx: Ctx) =
    returnif: not ctx.requireAdmin()
    var limit = DefaultLimit
    let lp = ctx.req.queryParam("limit")
    if lp.len > 0:
        try: limit = parseInt(lp)
        except ValueError: limit = DefaultLimit
    limit = max(1, min(limit, MaxLimit))

    # Each line is `timestamp ip method path status durationms`; the timestamp itself holds a space
    # (`date time`) and paths are URL-encoded (no spaces), so a plain split yields exactly 7 tokens.
    # Build the JSON ad-hoc (not via serialize): `method` is a Nim keyword and can't be a field name.
    var arr = newJArray()
    for line in accesslog.recentLines(limit):
        let p = line.split(' ')
        if p.len < 7: continue                          # skip malformed lines
        arr.add %*{
            "timestamp": p[0] & " " & p[1],
            "ip": p[2],
            "method": p[3],
            "path": p[4],
            "status": p[5],
            "duration": p[6],                           # e.g. "12ms"
        }
    ctx.req.respond(200, $arr)
