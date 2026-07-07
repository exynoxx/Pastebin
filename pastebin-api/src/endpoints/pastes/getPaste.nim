## GET /api/pastes/{id} — one paste's metadata + (inline) content.

import std/[json, options]
import ../routes
import ../../types, ../../db, ../../json

serialize(Paste, omit = [blobId])

proc handleGetPaste*(ctx: Ctx, id: string) =
    let p = fetchOr404(ctx, selectPaste(id), "Paste not found")
    ctx.req.respond(200, pasteJson(p))
