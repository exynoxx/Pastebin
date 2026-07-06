## DELETE /api/admin/pastes/{id} — admin delete a paste and its backing blob (if any).

import std/[json, options]
import ../context, guard
import ../../types, ../../db, ../../blobstore

proc handleAdminDeletePaste*(ctx: Ctx) =
    if not ctx.requireAdmin(): return
    let p = fetchOr404(ctx, selectPaste(ctx.params[0]), "Paste not found")
    if p.blobId.len > 0:
        discard deleteBlob(p.blobId)
    if deletePasteRow(ctx.params[0]):
        ctx.req.respond(200, $(%*{"message": "Paste deleted successfully"}))
    else:
        ctx.respondError(404, "Paste not found")
