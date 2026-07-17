## GET /api/pastes/{id} — one paste's metadata + (inline) content.

import std/[json, options]
import ../routes
referencing db
referencing pastecache
import ../../types, ../../json

serialize(Paste, omit = [blobId])

proc handleGetPaste*(ctx: Ctx, id: string) =
    let cached = pastecache.getDisplayPaste(id)
    if cached.isSome:
        ctx.req.respond(200, pasteJson(cached.get))
        return
    let p = fetchOr404(ctx, db.selectPaste(id), "Paste not found")
    ctx.req.respond(200, pasteJson(p))
