## GET /api/pastes — the most recent public pastes/files (default 10, ?limit=N).

import std/[json, strutils]
import ../routes
referencing db
import ../../types, ../../json

serialize(PasteSummary)

const
    DefaultLimit = 10
    MaxLimit = 100

func summariesJson(items: seq[PasteSummary]): string

proc handleRecentPastes*(ctx: Ctx) =
    var limit = DefaultLimit
    let lp = ctx.req.queryParam("limit")
    if lp.len > 0:
        try: limit = parseInt(lp)
        except ValueError: limit = DefaultLimit
    # Clamp: parseInt("-1") succeeds without raising, and SQLite treats a negative LIMIT as
    # unbounded — so an unclamped ?limit=-1 would dump the entire pastes+files union.
    limit = max(1, min(limit, MaxLimit))
    ctx.req.respond(200, summariesJson(db.selectRecentSummaries(limit)))

func summariesJson(items: seq[PasteSummary]): string =
    ## Assemble the array from the macro-generated per-item node builder.
    var arr = newJArray()
    for s in items:
        arr.add pasteSummaryNode(s)
    $arr
