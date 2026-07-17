## DELETE /api/files/{id} — delete a file and its backing blob.

import std/[json, options]
import ../routes, ../admin/guard
from ../../db import nil
import ../../types, ../../blobstore

proc handleDeleteFile*(ctx: Ctx, id: string) =
    returnif: not ctx.requireAdmin()
    let f = fetchOr404(ctx, db.selectFile(id), "File not found")
    if f.blobId.len > 0:
        discard deleteBlob(f.blobId)
    if db.deleteFileRow(id):
        ctx.req.respond(200, $(%*{"message": "File deleted successfully"}))
    else:
        ctx.respondError(404, "File not found")
