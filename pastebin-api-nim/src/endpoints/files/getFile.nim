## GET /api/files/{id} — file metadata.

import std/options
import ../context
import ../../db

proc handleGetFile*(ctx: Ctx) =
    let f = selectFile(ctx.params[0])
    if f.isNone: ctx.respondError(404, "File not found")
    else: ctx.req.respond(200, storedFileJson(f.get))
