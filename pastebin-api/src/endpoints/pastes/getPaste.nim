## GET /api/pastes/{id} — one paste's metadata + (inline) content.

import std/[json, options]
import ../context
import ../../types, ../../db, ../../json

serialize(Paste, omit = [blobId])

proc handleGetPaste*(ctx: Ctx) =
    let p = fetchOr404(ctx, selectPaste(ctx.params[0]), "Paste not found")
    ctx.req.respond(200, pasteJson(p))
