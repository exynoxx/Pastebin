## GET /api/pastes — the most recent public pastes/files (default 10, ?limit=N).

import std/json
import ../routes
referencing db
import ../../types, ../../json

serialize(PasteSummary)

const
    DefaultLimit = 10
    MaxLimit = 100

func summariesJson(items: seq[PasteSummary]): string

proc handleRecentPastes*(ctx: Ctx) =
    let limit = ctx.clampedQueryInt("limit", DefaultLimit, 1, MaxLimit)
    ctx.req.respond(200, summariesJson(db.selectRecentSummaries(limit)))

func summariesJson(items: seq[PasteSummary]): string =
    ## Assemble the array from the macro-generated per-item node builder.
    var arr = newJArray()
    for s in items:
        arr.add pasteSummaryNode(s)
    $arr
