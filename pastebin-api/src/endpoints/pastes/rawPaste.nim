## GET /api/pastes/{id}/raw — full raw content: from the memory cache, a streamed blob (Range-capable),
## or inline text. A cache hit serves the full content from RAM while the paste is still pending; once
## it is persisted and blob-backed we stream from disk so Range keeps working.

import std/options
import ../routes
referencing db
referencing blobstore
referencing pastecache
import ../../types

proc handleRawPaste*(ctx: Ctx, id: string) =
    let rv = pastecache.acquireForRaw(id)
    if rv.isSome:
        let v = rv.get
        if (not v.dirty) and v.blobId.len > 0 and blobstore.blobExists(v.blobId):
            ctx.req.respondFile(blobstore.blobPath(v.blobId), "text/plain; charset=utf-8",rangeHeader = ctx.req.header("Range"))
        else:
            ctx.req.respond(200, pastecache.content(v), contentType = "text/plain; charset=utf-8")
        return
    let p = db.selectPaste(id).getOr404(ctx, "Paste not found")
    if p.blobId.len > 0 and blobstore.blobExists(p.blobId):
        ctx.req.respondFile(blobstore.blobPath(p.blobId), "text/plain; charset=utf-8",rangeHeader = ctx.req.header("Range"))
    else:
        ctx.req.respond(200, p.content, contentType = "text/plain; charset=utf-8")
