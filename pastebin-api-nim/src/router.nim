## HTTP routing + request handling — the integration layer that maps the 12 endpoints to the
## services, mirroring pastebin-api/controllers/*. Runs on the httpserver worker threads.

import std/[json, strutils, options, os]
import httpserver, config, clientip, jsonbuild, apperrors, timeutil
import pastes, files, ratelimit, pasteguard, adminguard, multipart, types

const BusyBody = "{\"error\":\"Server busy or rate limit exceeded. Please retry shortly.\"}"

# ---- small response helpers ------------------------------------------------

proc respondError(req: Request, code: int, msg: string) =
    req.respond(code, errorJson(msg))

proc respondBusy(req: Request) =
    req.respond(503, BusyBody, extraHeaders = [("Retry-After", "10")])

proc rejectPasteGuard(req: Request, d: Decision): bool =
    ## Returns true (and responds 429) when the paste is rate-limited; false when allowed.
    if d.allowed: return false
    let msg =
        if d.penalized:
            "Too many pastes. You've been rate-limited to 1 paste per minute for a while — please slow down."
        else:
            "Too many pastes in a short time. Please wait a moment and try again."
    let body = $(%*{
        "error": msg,
        "retryAfterSeconds": d.retryAfterSeconds,
        "penalized": d.penalized,
    })
    req.respond(429, body, extraHeaders = [("Retry-After", $d.retryAfterSeconds)])
    true

# ---- paste endpoints -------------------------------------------------------

proc handleCreatePaste(cfg: AppConfig, req: Request, ip: string) =
    var root: JsonNode
    try:
        root = parseJson(req.bodyString())
    except CatchableError:
        respondError(req, 400, "Invalid request body")
        return
    let content = root{"content"}.getStr("")
    if content.strip().len == 0:
        respondError(req, 400, "Content cannot be empty")
        return
    if rejectPasteGuard(req, check(ip)): return
    let title = root{"title"}.getStr("")
    let visibility = root{"visibility"}.getStr("public")
    try:
        let p = createPaste(cfg, title, content, visibility, ip)
        req.respond(200, $(%*{"id": p.id}))
    except PayloadTooLargeError as e:
        respondError(req, 413, e.msg)

proc handleGetPaste(req: Request, id: string) =
    let p = getPaste(id)
    if p.isNone: respondError(req, 404, "Paste not found")
    else: req.respond(200, pasteJson(p.get))

proc handleRawPaste(req: Request, id: string) =
    let d = openRaw(id)
    if d.isNone:
        respondError(req, 404, "Paste not found")
        return
    let dd = d.get
    if dd.fromBlob:
        req.respondFile(dd.blobPath, dd.contentType, rangeHeader = req.header("Range"))
    else:
        req.respond(200, dd.inlineData, contentType = dd.contentType)

proc handleRecentPastes(req: Request) =
    var limit = 10
    let lp = req.queryParam("limit")
    if lp.len > 0:
        try: limit = parseInt(lp)
        except ValueError: limit = 10
    req.respond(200, summariesJson(getRecentPastes(limit)))

# ---- admin endpoints -------------------------------------------------------

proc handleAdminListPastes(req: Request) =
    req.respond(200, adminPastesJson(listAllPastes()))

proc handleAdminDeletePaste(req: Request, id: string) =
    if deletePaste(id): req.respond(200, "{\"message\":\"Paste deleted successfully\"}")
    else: respondError(req, 404, "Paste not found")

# ---- file endpoints --------------------------------------------------------

proc handleUploadFile(cfg: AppConfig, req: Request, ip: string) =
    var entries: seq[MultipartEntry]
    try:
        entries = parseMultipart(req.bodyFile(), req.header("Content-Type"))
    except CatchableError:
        respondError(req, 400, "No file provided")
        return
    var fileEntry: Option[MultipartEntry]
    var visibility = "public"
    for e in entries:
        if e.name == "file" and e.isFile: fileEntry = some(e)
        elif e.name == "visibility": visibility = e.value
    if fileEntry.isNone or fileEntry.get.size == 0:
        cleanupEntries(entries)
        respondError(req, 400, "No file provided")
        return
    try:
        let r = uploadFile(cfg, fileEntry.get, ip, visibility)
        req.respond(200, fileUploadResultJson(r))
    except PayloadTooLargeError as e:
        respondError(req, 413, e.msg)
    except CatchableError as e:
        respondError(req, 500, "Upload failed: " & e.msg)
    finally:
        cleanupEntries(entries)

proc handleUploadFolder(cfg: AppConfig, req: Request, ip: string) =
    var entries: seq[MultipartEntry]
    try:
        entries = parseMultipart(req.bodyFile(), req.header("Content-Type"))
    except CatchableError:
        respondError(req, 400, "No files provided")
        return
    var fileParts: seq[MultipartEntry]
    var folderName = ""
    var visibility = "public"
    for e in entries:
        if e.isFile and e.name == "files": fileParts.add e
        elif e.name == "folderName": folderName = e.value
        elif e.name == "visibility": visibility = e.value
    if fileParts.len == 0:
        cleanupEntries(entries)
        respondError(req, 400, "No files provided")
        return
    try:
        let r = uploadFolder(cfg, fileParts, folderName, ip, visibility)
        req.respond(200, fileUploadResultJson(r))
    except PayloadTooLargeError as e:
        respondError(req, 413, e.msg)
    except CatchableError as e:
        respondError(req, 500, "Folder upload failed: " & e.msg)
    finally:
        cleanupEntries(entries)

proc handleCreatePasteFromFile(cfg: AppConfig, req: Request, ip: string) =
    var root: JsonNode
    try:
        root = parseJson(req.bodyString())
    except CatchableError:
        respondError(req, 400, "Invalid request body")
        return
    if rejectPasteGuard(req, check(ip)): return
    let fileId = root{"fileId"}.getStr("")
    let fo = getFile(fileId)
    if fo.isNone:
        respondError(req, 404, "File not found")
        return
    let f = fo.get
    let reqTitle = root{"title"}.getStr("")
    let title = if reqTitle.strip().len == 0: f.originalName else: reqTitle.strip()
    let visibility = root{"visibility"}.getStr("public")
    let content =
        "[FILE ATTACHMENT]\nFile: " & f.originalName & "\nSize: " & $f.size & " bytes\n" &
        "Type: " & f.contentType & "\nUploaded: " & isoToUniversal(f.uploadedAt) & "\n\n" &
        "File ID: " & f.id & "\nDownload: /api/files/" & f.id & "/download"
    try:
        let p = createPaste(cfg, title, content, visibility, ip)
        req.respond(200, $(%*{"pasteId": p.id, "id": p.id}))
    except PayloadTooLargeError as e:
        respondError(req, 413, e.msg)

proc handleGetFile(req: Request, id: string) =
    let f = getFile(id)
    if f.isNone: respondError(req, 404, "File not found")
    else: req.respond(200, storedFileJson(f.get))

proc handleDownloadFile(req: Request, id: string) =
    let d = downloadFile(id)
    if d.isNone:
        respondError(req, 404, "File not found")
        return
    let dd = d.get
    let disposition = "attachment; filename=\"" & dd.fileName.replace("\"", "") & "\""
    req.respondFile(dd.blobPath, dd.contentType,
        rangeHeader = req.header("Range"), contentDisposition = disposition)

proc handleViewFile(req: Request, id: string) =
    let d = downloadFile(id)
    if d.isNone:
        respondError(req, 404, "File not found")
        return
    let dd = d.get
    req.respondFile(dd.blobPath, dd.contentType,
        rangeHeader = req.header("Range"), noSniff = true)

proc handleDeleteFile(req: Request, id: string) =
    if deleteFile(id): req.respond(200, "{\"message\":\"File deleted successfully\"}")
    else: respondError(req, 404, "File not found")

proc handleDebugIp(req: Request) =
    req.respond(200, $(%*{
        "resolvedClientIp": resolveClientIp(req),
        "xForwardedFor": req.header("X-Forwarded-For"),
        "xRealIp": req.header("X-Real-IP"),
        "xForwardedProto": req.header("X-Forwarded-Proto"),
        "connectionRemoteIp": req.remoteAddress,
        "host": req.header("Host"),
    }))

# ---- dispatch --------------------------------------------------------------

proc dispatch(cfg: AppConfig, req: Request) =
    let m = req.httpMethod
    let segs = req.path.strip(chars = {'/'}).split('/')
    if segs.len < 2 or segs[0] != "api":
        respondError(req, 404, "Not found")
        return

    let ip = resolveClientIp(req)

    # ["api","pastes", ...]
    if segs[1] == "pastes":
        if segs.len == 2:
            if m == "GET": handleRecentPastes(req)
            elif m == "POST": handleCreatePaste(cfg, req, ip)
            else: respondError(req, 404, "Not found")
        elif segs.len == 3:
            if m == "GET": handleGetPaste(req, segs[2])
            else: respondError(req, 404, "Not found")
        elif segs.len == 4 and segs[3] == "raw" and m == "GET":
            handleRawPaste(req, segs[2])
        else:
            respondError(req, 404, "Not found")
        return

    # ["api","files", ...]
    if segs[1] == "files":
        if segs.len == 3:
            case segs[2]
            of "upload":
                if m == "POST":
                    handleUploadFile(cfg, req, ip)
                else:
                    respondError(req, 404, "Not found")
            of "upload-folder":
                if m == "POST":
                    handleUploadFolder(cfg, req, ip)
                else:
                    respondError(req, 404, "Not found")
            of "create-paste-from-file":
                if m == "POST":
                    handleCreatePasteFromFile(cfg, req, ip)
                else:
                    respondError(req, 404, "Not found")
            else:
                if m == "GET": handleGetFile(req, segs[2])
                elif m == "DELETE": handleDeleteFile(req, segs[2])
                else: respondError(req, 404, "Not found")
        elif segs.len == 4 and segs[3] == "download" and m == "GET":
            handleDownloadFile(req, segs[2])
        elif segs.len == 4 and segs[3] == "raw" and m == "GET":
            handleViewFile(req, segs[2])
        else:
            respondError(req, 404, "Not found")
        return

    # ["api","admin", ...] — guarded by a shared-secret token. Fail-closed: an unset
    # ADMIN_TOKEN (or a mismatch) rejects every admin request with 401. Because the token is
    # short, adminguard makes guessing expensive: an escalating per-IP lockout (instant 429
    # while cooling down) plus a fixed delay + constant-time compare on each failed attempt.
    if segs[1] == "admin":
        let gate = adminPrecheck(ip)
        if gate.lockedOut:
            req.respond(429, errorJson("Too many failed admin attempts. Try again later."),
                extraHeaders = [("Retry-After", $gate.retryAfterSeconds)])
            return
        if cfg.adminToken.len == 0 or not constantTimeEq(req.header("X-Admin-Token"), cfg.adminToken):
            registerAdminFailure(ip)
            sleep(AdminFailPenaltyMs)
            respondError(req, 401, "Unauthorized")
            return
        clearAdminFailures(ip)
        if segs.len == 3 and segs[2] == "pastes" and m == "GET":
            handleAdminListPastes(req)
        elif segs.len == 4 and segs[2] == "pastes" and m == "DELETE":
            handleAdminDeletePaste(req, segs[3])
        else:
            respondError(req, 404, "Not found")
        return

    if segs[1] == "debug" and segs.len == 3 and segs[2] == "ip" and m == "GET":
        handleDebugIp(req)
        return

    respondError(req, 404, "Not found")

proc route*(cfg: AppConfig, req: Request) =
    ## Top-level entry: apply the 3-tier framework limiter (+ uploads policy), then dispatch.
    let ip = resolveClientIp(req)
    let isUpload = req.httpMethod == "POST" and
        (req.path == "/api/files/upload" or req.path == "/api/files/upload-folder")
    let acq = tryAcquire(ip, isUpload)
    if not acq.allowed:
        respondBusy(req)
        return
    try:
        dispatch(cfg, req)
    finally:
        if acq.concurrencyHeld: releaseConcurrency()
