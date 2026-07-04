## DELETE /api/files/{id} — delete a file and its backing blob.

import std/[json, options]
import ../context
import ../../types, ../../db, ../../blobstore

proc handleDeleteFile*(ctx: Ctx) =
    let fo = selectFile(ctx.params[0])
    if fo.isNone:
        ctx.respondError(404, "File not found")
        return
    let f = fo.get
    if f.blobId.len > 0:
        discard deleteBlob(f.blobId)
    if deleteFileRow(ctx.params[0]):
        ctx.req.respond(200, $(%*{"message": "File deleted successfully"}))
    else:
        ctx.respondError(404, "File not found")
