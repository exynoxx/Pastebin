## POST /api/files/create-paste-from-file — make a paste that points at an already-uploaded file.
## Reuses the paste-creation pipeline that lives in the create-paste slice.

import std/[json, strutils, options]
import ../routes
from ../../db import nil
import ../../types, ../../apperrors, ../../ratelimit, ../../timeutil, ../../macros
import ../pastes/createPaste

proc handleCreatePasteFromFile*(ctx: Ctx) =
    let root = parseJsonBodyOr400(ctx)
    let fileId = root{"fileId"}.getStr("")
    # Resolve the file BEFORE the paste rate-limit check: checkPasteCreate records into the burst
    # window / trips the penalty box, so a run of requests with a bad fileId must not consume that
    # budget (or penalty-box the IP) when no paste is ever created.
    let f = fetchOr404(ctx, db.selectFile(fileId), "File not found")
    returnif: ctx.rejectPasteLimit(checkPasteCreate(ctx.ip))
    let reqTitle = root{"title"}.getStr("")
    let title = if reqTitle.strip().len == 0: f.originalName else: reqTitle.strip()
    let visibility = root{"visibility"}.getStr("public")
    let content =
        "[FILE ATTACHMENT]\nFile: " & f.originalName & "\nSize: " & $f.size & " bytes\n" &
        "Type: " & f.contentType & "\nUploaded: " & formatMillisUtc(f.uploadedAt) & "\n\n" &
        "File ID: " & f.id & "\nDownload: /api/files/" & f.id & "/download"
    try:
        let p = createPasteRecord(ctx.cfg, title, content, visibility, ctx.ip)
        ctx.req.respond(200, $(%*{"id": p.id}))
    except PayloadTooLargeError as e:
        ctx.respondError(413, e.msg)
