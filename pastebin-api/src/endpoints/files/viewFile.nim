## GET /api/files/{id}/raw — view the file inline (X-Content-Type-Options: nosniff).

import std/options
import ../routes
import ../../types
import downloadFile

proc handleViewFile*(ctx: Ctx, id: string) =
    let dd = resolveDownload(id).getOr404(ctx, "File not found")
    ctx.req.respondFile(dd.blobPath, dd.contentType,
        rangeHeader = ctx.req.header("Range"), noSniff = true)
