## GET /api/pastes/{id}/raw — full raw content: from the write queue while the paste is still
## unwritten, else a streamed blob (Range-capable) or inline text from SQLite. Not the read cache,
## which holds only the display shape — a preview for a large paste.

import std/options
import ../routes
referencing db
referencing blobstore
referencing writequeue
import ../../types

proc handleRawPaste*(ctx: Ctx, id: string) =
    let pend = writequeue.pending(id)
    if pend != nil:
        ctx.req.respond(200, pend.content, contentType = "text/plain; charset=utf-8")
        return
    let p = db.selectPaste(id).getOr404(ctx, "Paste not found")
    if p.blobId.len > 0 and blobstore.blobExists(p.blobId):
        ctx.req.respondFile(blobstore.blobPath(p.blobId), "text/plain; charset=utf-8",rangeHeader = ctx.req.header("Range"))
    else:
        ctx.req.respond(200, p.content, contentType = "text/plain; charset=utf-8")
