## DELETE /api/admin/pastes/{id} — admin delete a paste and its backing blob (if any).

import std/[json, options]
import ../routes, guard
import ../../types, ../../db, ../../blobstore

proc handleAdminDeletePaste*(ctx: Ctx, id: string) =
    if not ctx.requireAdmin(): return
    let p = fetchOr404(ctx, selectPaste(id), "Paste not found")
    if p.blobId.len > 0:
        discard deleteBlob(p.blobId)
    if deletePasteRow(id):
        ctx.req.respond(200, $(%*{"message": "Paste deleted successfully"}))
    else:
        ctx.respondError(404, "Paste not found")
