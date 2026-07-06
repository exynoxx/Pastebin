## GET /api/files/{id} — file metadata.

import std/options
import ../context, ../../json
import ../../db

proc handleGetFile*(ctx: Ctx, id: string) =
    let f = fetchOr404(ctx, selectFile(id), "File not found")
    ctx.req.respond(200, storedFileJson(f))
