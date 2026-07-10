## DELETE /api/admin/pastes/{id} — admin delete a paste and its backing blob (if any).
## Evicts the in-memory copy too: a paste may exist only in the cache (not yet persisted), or in both
## the cache and SQLite. removeFromCache reports the on-disk blob (if the paste was already flushed) so
## we can delete it; the persister's post-write presence check cleans up any in-flight write.

import std/[json, options]
import ../routes, guard
import ../../types, ../../db, ../../blobstore, ../../pastecache

proc handleAdminDeletePaste*(ctx: Ctx, id: string) =
    if not ctx.requireAdmin(): return
    let cached = removeFromCache(id)
    if cached.wasCached:
        if cached.blobId.len > 0: discard deleteBlob(cached.blobId)
        discard deletePasteRow(id)   # no-op if it was never persisted
        ctx.req.respond(200, $(%*{"message": "Paste deleted successfully"}))
        return
    let p = fetchOr404(ctx, selectPaste(id), "Paste not found")
    if p.blobId.len > 0:
        discard deleteBlob(p.blobId)
    if deletePasteRow(id):
        ctx.req.respond(200, $(%*{"message": "Paste deleted successfully"}))
    else:
        ctx.respondError(404, "Paste not found")
