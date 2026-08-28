## DELETE /api/admin/pastes/{id} — admin delete a paste and its backing blob (if any).
## A paste may be queued (not yet written), cached for reads, and/or in SQLite, so all three are
## cleared. Cancelling a queued paste is a delete on its own — hence the `or wasQueued`; a write
## already in flight is rolled back by the persister's post-write presence check.

import std/[json, options]
import ../routes, guard
import ../../types
referencing db
referencing blobstore
referencing pastecache
referencing writequeue

proc handleAdminDeletePaste*(ctx: Ctx, id: string) =
    returnif: not ctx.requireAdmin()
    let wasQueued = writequeue.cancel(id)
    pastecache.remove(id)
    let p = db.selectPaste(id)
    if p.isSome and p.get.blobId.len > 0:
        discard blobstore.deleteBlob(p.get.blobId)
    if db.deletePasteRow(id) or wasQueued:
        ctx.req.respond(200, $(%*{"message": "Paste deleted successfully"}))
    else:
        ctx.respondError(404, "Paste not found")
