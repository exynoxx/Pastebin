## GET /api/pastes — the most recent public pastes/files (default 10, ?limit=N).

import std/strutils
import ../context
import ../../db

proc handleRecentPastes*(ctx: Ctx) =
    var limit = 10
    let lp = ctx.req.queryParam("limit")
    if lp.len > 0:
        try: limit = parseInt(lp)
        except ValueError: limit = 10
    ctx.req.respond(200, summariesJson(selectRecentSummaries(limit)))
