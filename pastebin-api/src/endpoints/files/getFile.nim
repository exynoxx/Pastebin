## GET /api/files/{id} — file metadata.

import std/options
import ../routes, ../../json
referencing db

proc handleGetFile*(ctx: Ctx, id: string) =
    let f = db.selectFile(id).getOr404(ctx, "File not found")
    ctx.req.respond(200, storedFileJson(f))
