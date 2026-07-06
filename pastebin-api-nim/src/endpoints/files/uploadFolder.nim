## POST /api/files/upload-folder — multipart multi-file upload, archived into a single zip.
##
## LIMITATION: zippy has no streaming zip writer, so entry contents are read into memory here,
## bounded by the per-IP quota reserved up front. Single-file uploads (the common path) stream.

import std/[strutils, tables, strformat]
import ../context, ../../json
import ../../types, ../../db, ../../blobstore, ../../quota, ../../ntfy,
       ../../timeutil, ../../apperrors, ../../webframework/multipart
import zippy/ziparchives

func zipEntryName(entry: MultipartEntry): string =
    ## Normalise a browser-supplied relative path to a safe forward-slash zip entry name.
    ## Strips drive/leading separators and any "."/".." segments (path-traversal safe).
    let raw = if entry.filename.strip().len == 0: entry.name else: entry.filename
    var parts: seq[string]
    for seg in raw.replace('\\', '/').split('/'):
        if seg.len > 0 and seg != "." and seg != "..":
            parts.add seg
    if parts.len > 0: parts.join("/") else: "file"

proc zipFileName(folderName: string): string =
    var name = if folderName.strip().len == 0: "folder" else: folderName.strip()
    # Keep to a single safe path segment; the client may pass a nested path.
    var last = "folder"
    for seg in name.replace('\\', '/').split('/'):
        if seg.len > 0: last = seg
    name = last
    if name.toLowerAscii().endsWith(".zip"): name else: name & ".zip"

proc handleUploadFolder*(ctx: Ctx) =
    var entries: seq[MultipartEntry]
    try:
        entries = parseMultipart(ctx.req.bodyFile(), ctx.req.header("Content-Type"))
    except CatchableError:
        ctx.respondError(400, "No files provided")
        return
    var fileParts: seq[MultipartEntry]
    var folderName = ""
    var visibility = "public"
    for e in entries:
        case e.name
        of "files":
            if e.isFile: fileParts.add e
        of "folderName": folderName = e.value
        of "visibility": visibility = e.value
        else: discard
    if fileParts.len == 0:
        cleanupEntries(entries)
        ctx.respondError(400, "No files provided")
        return
    try:
        var uncompressedTotal: int64 = 0
        for e in fileParts: uncompressedTotal += e.size
        if uncompressedTotal > ctx.cfg.maxRequestBytes:
            raise newException(PayloadTooLargeError,
                &"Folder size exceeds the maximum allowed size of {ctx.cfg.maxRequestBytes div (1024*1024)}MB")
        ensureWithinQuota(ctx.ip, uncompressedTotal, ctx.cfg.maxStorageBytesPerIp)
        var zipEntries: OrderedTable[string, string]
        for e in fileParts:
            zipEntries[zipEntryName(e)] = readFile(e.dataFilePath)
        let zipBytes = createZipArchive(zipEntries)
        let (blobId, size) = saveFromString(zipBytes)
        let f = StoredFile(
            id: randomHex(6),
            originalName: zipFileName(folderName),
            contentType: "application/zip",
            size: size,
            uploadedAt: nowIso(),
            visibility: (if visibility == "private": "private" else: "public"),
            blobId: blobId)
        insertFile(f, ctx.ip)
        notifyFileUploaded(f)
        ctx.req.respond(200, storedFileJson(f))
    except PayloadTooLargeError as e:
        ctx.respondError(413, e.msg)
    except CatchableError as e:
        ctx.respondError(500, "Folder upload failed: " & e.msg)
    finally:
        cleanupEntries(entries)
