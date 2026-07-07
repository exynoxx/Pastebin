## GET /api/pastes/{id}/raw — full raw content: a streamed blob (Range-capable) or inline text.

import std/options
import ../routes
import ../../types, ../../db, ../../blobstore

proc handleRawPaste*(ctx: Ctx, id: string) =
    let p = fetchOr404(ctx, selectPaste(id), "Paste not found")
    if p.blobId.len > 0 and blobExists(p.blobId):
        ctx.req.respondFile(blobPath(p.blobId), "text/plain; charset=utf-8",
            rangeHeader = ctx.req.header("Range"))
    else:
        ctx.req.respond(200, p.content, contentType = "text/plain; charset=utf-8")
