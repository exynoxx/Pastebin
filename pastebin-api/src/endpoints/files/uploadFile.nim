## POST /api/files/upload — multipart single-file upload (streams the body straight into a blob).

import std/[options, strformat]
import ../routes, ../../json
import ../../types, ../../apperrors, webframework/multipart
referencing db
referencing blobstore
referencing quota
referencing ntfy
referencing timeutil
referencing ids

proc handleUploadFile*(ctx: Ctx) =
    var entries: seq[MultipartEntry]
    try:
        entries = parseMultipart(ctx.req.bodyFile(), ctx.req.header("Content-Type"))
    except CatchableError:
        ctx.respondError(400, "No file provided")
        return
    var fileEntry: Option[MultipartEntry]
    var visibility = "public"
    for e in entries:
        case e.name
        of "file":
            if e.isFile: fileEntry = some(e)
        of "visibility": visibility = e.value
        else: discard
    if fileEntry.isNone or fileEntry.get.size == 0:
        cleanupEntries(entries)
        ctx.respondError(400, "No file provided")
        return
    let entry = fileEntry.get
    try:
        if entry.size > ctx.cfg.maxFileUploadBytes:
            raise newException(PayloadTooLargeError,
                &"File size exceeds the maximum allowed size of {ctx.cfg.maxFileUploadBytes div (1024*1024)}MB")
        quota.ensureWithinQuota(ctx.ip, entry.size, ctx.cfg.maxStorageBytesPerIp)
        # Stream the spilled request-body part straight into a blob (flat memory).
        let (blobId, size) = blobstore.saveFromFile(entry.dataFilePath)
        let f = StoredFile(
            id: ids.newId(),
            originalName: entry.filename,
            contentType: (if entry.contentType.len == 0: "application/octet-stream" else: entry.contentType),
            size: size,
            uploadedAt: timeutil.nowMillis(),
            visibility: types.normalizeVisibility(visibility),
            blobId: blobId)
        db.insertFile(f, ctx.ip)
        ntfy.notifyFileUploaded(f)
        ctx.req.respond(200, storedFileJson(f))
    except PayloadTooLargeError as e:
        ctx.respondError(413, e.msg)
    except CatchableError as e:
        ctx.respondError(500, "Upload failed: " & e.msg)
    finally:
        cleanupEntries(entries)
