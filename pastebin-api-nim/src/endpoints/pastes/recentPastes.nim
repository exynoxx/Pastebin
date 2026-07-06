## GET /api/pastes — the most recent public pastes/files (default 10, ?limit=N).

import std/[json, strutils]
import ../context
import ../../types, ../../db, ../../json

serialize(PasteSummary)

func summariesJson(items: seq[PasteSummary]): string =
    ## Assemble the array from the macro-generated per-item node builder.
    var arr = newJArray()
    for s in items: arr.add pasteSummaryNode(s)
    $arr

proc handleRecentPastes*(ctx: Ctx) =
    var limit = 10
    let lp = ctx.req.queryParam("limit")
    if lp.len > 0:
        try: limit = parseInt(lp)
        except ValueError: limit = 10
    ctx.req.respond(200, summariesJson(selectRecentSummaries(limit)))
