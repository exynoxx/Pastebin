## GET /api/files/{id}/raw — view the file inline (X-Content-Type-Options: nosniff).

import std/options
import ../context
import ../../types
import downloadFile

proc handleViewFile*(ctx: Ctx, id: string) =
    let dd = fetchOr404(ctx, resolveDownload(id), "File not found")
    ctx.req.respondFile(dd.blobPath, dd.contentType,
        rangeHeader = ctx.req.header("Range"), noSniff = true)
