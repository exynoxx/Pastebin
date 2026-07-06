## GET /api/files/{id} — file metadata.

import std/options
import ../context, ../../json
import ../../db

proc handleGetFile*(ctx: Ctx) =
    let f = fetchOr404(ctx, selectFile(ctx.params[0]), "File not found")
    ctx.req.respond(200, storedFileJson(f))
