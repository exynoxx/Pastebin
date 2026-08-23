## GET /api/pastes — the most recent public pastes/files (default 10, ?limit=N).

import ../routes
referencing db
import ../../json

const
    DefaultLimit = 10
    MaxLimit = 100

proc handleRecentPastes*(ctx: Ctx) =
    let limit = ctx.clampedQueryInt("limit", DefaultLimit, 1, MaxLimit)
    ctx.req.respond(200, pasteSummariesJson(db.selectRecentSummaries(limit)))
