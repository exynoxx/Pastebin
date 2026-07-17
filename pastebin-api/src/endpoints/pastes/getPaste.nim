## GET /api/pastes/{id} — one paste's metadata + (inline) content.

import std/[json, options]
import ../routes
importuse db
importuse pastecache
import ../../types, ../../json

serialize(Paste, omit = [blobId])

proc handleGetPaste*(ctx: Ctx, id: string) =
    if ctx.cfg.pasteCacheEnabled:
        let cached = pastecache.getDisplayPaste(id)
        if cached.isSome:
            ctx.req.respond(200, pasteJson(cached.get))
            return
    let p = fetchOr404(ctx, db.selectPaste(id), "Paste not found")
    ctx.req.respond(200, pasteJson(p))
