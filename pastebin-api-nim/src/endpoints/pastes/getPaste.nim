## GET /api/pastes/{id} — one paste's metadata + (inline) content.

import std/options
import ../context
import ../../db

proc handleGetPaste*(ctx: Ctx) =
    let p = selectPaste(ctx.params[0])
    if p.isNone: ctx.respondError(404, "Paste not found")
    else: ctx.req.respond(200, pasteJson(p.get))
