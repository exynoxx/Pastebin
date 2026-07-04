## DELETE /api/admin/pastes/{id} — admin delete a paste and its backing blob (if any).

import std/[json, options]
import ../context, guard
import ../../types, ../../db, ../../blobstore

proc handleAdminDeletePaste*(ctx: Ctx) =
    if not ctx.requireAdmin(): return
    let po = selectPaste(ctx.params[0])
    if po.isNone:
        ctx.respondError(404, "Paste not found")
        return
    let p = po.get
    if p.blobId.len > 0:
        discard deleteBlob(p.blobId)
    if deletePasteRow(ctx.params[0]):
        ctx.req.respond(200, $(%*{"message": "Paste deleted successfully"}))
    else:
        ctx.respondError(404, "Paste not found")
