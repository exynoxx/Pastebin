## GET /api/pastes — the most recent public pastes/files (default 10, ?limit=N).

import std/[json, strutils]
import ../context
import ../../types, ../../db

func summariesJson(items: seq[PasteSummary]): string =
    ## camelCase to match ASP.NET's default output; contentType is JSON null (not "") when empty.
    # Explicit accumulation, not `collect`: JsonNode isn't a collect-supported
    # container, and this is a per-request response path (guide §10 RSS caveat).
    var arr = newJArray()
    for s in items:
        arr.add %*{
            "id": s.id,
            "title": s.title,
            "size": s.size,
            "createdAt": s.createdAt,
            "kind": s.kind,
            "contentType": (if s.contentType.len == 0: newJNull() else: %s.contentType),
        }
    $arr

proc handleRecentPastes*(ctx: Ctx) =
    var limit = 10
    let lp = ctx.req.queryParam("limit")
    if lp.len > 0:
        try: limit = parseInt(lp)
        except ValueError: limit = 10
    ctx.req.respond(200, summariesJson(selectRecentSummaries(limit)))
