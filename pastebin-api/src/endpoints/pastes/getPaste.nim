## GET /api/pastes/{id} — one paste's metadata + (inline) content.

import std/[json, options]
import ../routes
import ../../types, ../../db, ../../json, ../../pastecache

serialize(Paste, omit = [blobId])

proc handleGetPaste*(ctx: Ctx, id: string) =
    let cached = getDisplayPaste(id)
    if cached.isSome:
        ctx.req.respond(200, pasteJson(cached.get))
        return
    let p = fetchOr404(ctx, selectPaste(id), "Paste not found")
    ctx.req.respond(200, pasteJson(p))
