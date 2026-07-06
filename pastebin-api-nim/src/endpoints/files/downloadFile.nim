## GET /api/files/{id}/download — stream the file as an attachment (Range-capable).
##
## `resolveDownload` (the blob lookup shared with the inline-view slice) is exported here.

import std/[options, strutils]
import ../context
import ../../types, ../../db, ../../blobstore

proc resolveDownload*(fileId: string): Option[DownloadData] =
    ## Resolve a file id to its on-disk blob, or none if the file/blob is missing.
    let fo = selectFile(fileId)
    if fo.isNone: return none(DownloadData)
    let f = fo.get
    if f.blobId.len == 0 or not blobExists(f.blobId): return none(DownloadData)
    some(DownloadData(kind: dkBlob, blobPath: blobPath(f.blobId),
        contentType: f.contentType, fileName: f.originalName))

proc handleDownloadFile*(ctx: Ctx) =
    let dd = fetchOr404(ctx, resolveDownload(ctx.params[0]), "File not found")
    let disposition = "attachment; filename=\"" & dd.fileName.replace("\"", "") & "\""
    ctx.req.respondFile(dd.blobPath, dd.contentType,
        rangeHeader = ctx.req.header("Range"), contentDisposition = disposition)
