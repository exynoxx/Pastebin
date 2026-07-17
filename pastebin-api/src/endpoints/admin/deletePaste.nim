## DELETE /api/admin/pastes/{id} — admin delete a paste and its backing blob (if any).
## Evicts the in-memory copy too: a paste may exist only in the cache (not yet persisted), or in both
## the cache and SQLite. removeFromCache reports the on-disk blob (if the paste was already flushed) so
## we can delete it; the persister's post-write presence check cleans up any in-flight write.

import std/[json, options]
import ../routes, guard
import ../../types
importuse db
importuse blobstore
importuse pastecache

proc handleAdminDeletePaste*(ctx: Ctx, id: string) =
    returnif: not ctx.requireAdmin()
    let cached = pastecache.removeFromCache(id)
    if cached.wasCached:
        if cached.blobId.len > 0: discard blobstore.deleteBlob(cached.blobId)
        discard db.deletePasteRow(id)   # no-op if it was never persisted
        ctx.req.respond(200, $(%*{"message": "Paste deleted successfully"}))
        return
    let p = fetchOr404(ctx, db.selectPaste(id), "Paste not found")
    if p.blobId.len > 0:
        discard blobstore.deleteBlob(p.blobId)
    if db.deletePasteRow(id):
        ctx.req.respond(200, $(%*{"message": "Paste deleted successfully"}))
    else:
        ctx.respondError(404, "Paste not found")
