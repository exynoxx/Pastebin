## DELETE /api/files/{id} — delete a file and its backing blob.

import std/[json, options]
import ../context, ../admin/guard
import ../../types, ../../db, ../../blobstore

proc handleDeleteFile*(ctx: Ctx, id: string) =
    if not ctx.requireAdmin(): return
    let f = fetchOr404(ctx, selectFile(id), "File not found")
    if f.blobId.len > 0:
        discard deleteBlob(f.blobId)
    if deleteFileRow(id):
        ctx.req.respond(200, $(%*{"message": "File deleted successfully"}))
    else:
        ctx.respondError(404, "File not found")
