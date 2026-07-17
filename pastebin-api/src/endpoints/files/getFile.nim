## GET /api/files/{id} — file metadata.

import std/options
import ../routes, ../../json
from ../../db import nil

proc handleGetFile*(ctx: Ctx, id: string) =
    let f = fetchOr404(ctx, db.selectFile(id), "File not found")
    ctx.req.respond(200, storedFileJson(f))
