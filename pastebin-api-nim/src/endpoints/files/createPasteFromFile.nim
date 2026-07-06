## POST /api/files/create-paste-from-file — make a paste that points at an already-uploaded file.
## Reuses the paste-creation pipeline that lives in the create-paste slice.

import std/[json, strutils, options]
import ../context
import ../../types, ../../db, ../../apperrors, ../../ratelimit, ../../timeutil
import ../pastes/createPaste

proc handleCreatePasteFromFile*(ctx: Ctx) =
    let root = parseJsonBodyOr400(ctx)
    if ctx.rejectPasteLimit(checkPasteCreate(ctx.ip)): return
    let fileId = root{"fileId"}.getStr("")
    let f = fetchOr404(ctx, selectFile(fileId), "File not found")
    let reqTitle = root{"title"}.getStr("")
    let title = if reqTitle.strip().len == 0: f.originalName else: reqTitle.strip()
    let visibility = root{"visibility"}.getStr("public")
    let content =
        "[FILE ATTACHMENT]\nFile: " & f.originalName & "\nSize: " & $f.size & " bytes\n" &
        "Type: " & f.contentType & "\nUploaded: " & isoToUniversal(f.uploadedAt) & "\n\n" &
        "File ID: " & f.id & "\nDownload: /api/files/" & f.id & "/download"
    try:
        let p = createPasteRecord(ctx.cfg, title, content, visibility, ctx.ip)
        ctx.req.respond(200, $(%*{"pasteId": p.id, "id": p.id}))
    except PayloadTooLargeError as e:
        ctx.respondError(413, e.msg)
