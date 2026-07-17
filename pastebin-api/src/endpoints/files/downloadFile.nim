## GET /api/files/{id}/download — stream the file as an attachment (Range-capable).
##
## `resolveDownload` (the blob lookup shared with the inline-view slice) is exported here.

import std/[options, strutils]
import ../routes
import ../../types
referencing db
referencing blobstore

func contentDispositionAttachment*(name: string): string =
    ## Build a safe `Content-Disposition: attachment` header value for a user-supplied filename.
    ##
    ## Two parts, per RFC 6266: a plain `filename="…"` for legacy clients (printable ASCII only,
    ## with the quote/backslash that break the quoted-string dropped) and an RFC 5987
    ## `filename*=UTF-8''…` whose bytes are percent-encoded so non-ASCII names survive intact.
    ## The name is UTF-8, so per-byte percent-encoding IS the RFC 5987 encoding. Control bytes
    ## (incl. CR/LF) never reach the header verbatim, so a crafted filename can't inject a header.
    const attrChars = {'A'..'Z', 'a'..'z', '0'..'9',
                       '!', '#', '$', '&', '+', '-', '.', '^', '_', '`', '|', '~'}
    var ascii = ""
    var encoded = ""
    for ch in name:
        let b = ord(ch)
        if ch in attrChars:
            encoded.add ch
        else:
            encoded.add '%'                    # percent-encode every other byte (covers all UTF-8)
            encoded.add toHex(b, 2)
        if b >= 0x20 and b < 0x7f and ch notin {'"', '\\'}:
            ascii.add ch                       # legacy fallback: printable ASCII, framing-safe
    if ascii.len == 0: ascii = "download"
    "attachment; filename=\"" & ascii & "\"; filename*=UTF-8''" & encoded

proc resolveDownload*(fileId: string): Option[DownloadData] =
    ## Resolve a file id to its on-disk blob, or none if the file/blob is missing.
    let fo = db.selectFile(fileId)
    if fo.isNone: return none(DownloadData)
    let f = fo.get
    if f.blobId.len == 0 or not blobstore.blobExists(f.blobId): return none(DownloadData)
    some(DownloadData(blobPath: blobstore.blobPath(f.blobId),
        contentType: f.contentType, fileName: f.originalName))

proc handleDownloadFile*(ctx: Ctx, id: string) =
    let dd = fetchOr404(ctx, resolveDownload(id), "File not found")
    let disposition = contentDispositionAttachment(dd.fileName)
    ctx.req.respondFile(dd.blobPath, dd.contentType,
        rangeHeader = ctx.req.header("Range"), contentDisposition = disposition)
