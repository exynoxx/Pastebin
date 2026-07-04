## GET /api/files/{id}/raw — view the file inline (X-Content-Type-Options: nosniff).

import std/options
import ../context
import ../../types
import downloadFile

proc handleViewFile*(ctx: Ctx) =
    let d = resolveDownload(ctx.params[0])
    if d.isNone:
        ctx.respondError(404, "File not found")
        return
    let dd = d.get
    ctx.req.respondFile(dd.blobPath, dd.contentType,
        rangeHeader = ctx.req.header("Range"), noSniff = true)
