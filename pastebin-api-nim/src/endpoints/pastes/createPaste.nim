## POST /api/pastes — create an inline/blob paste from a JSON body.
##
## `createPasteRecord` — the size-check → quota → inline-vs-blob → persist → notify pipeline — is
## the one bit of paste logic shared with the create-paste-from-file slice, so it is exported here
## (its canonical home) rather than living in a separate service layer.

import std/[json, strutils, unicode, sysrand, strformat]
import ../context
import ../../types, ../../db, ../../blobstore, ../../quota, ../../ntfy,
       ../../timeutil, ../../apperrors, ../../ratelimit

const IdAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

proc generateId(): string =
    ## 8 chars from IdAlphabet, using a thread-safe CSPRNG (sysrand).
    let bytes = urandom(8)
    result = newStringOfCap(8)
    for b in bytes:
        result.add IdAlphabet[int(b) mod IdAlphabet.len]

func deriveTitle(content: string, maxChars: int): string =
    ## First non-empty line, trimmed and capped at maxChars chars ("…" appended when cut).
    var firstLine = ""
    for rawLine in content.split('\n'):
        let line = rawLine.strip()
        if line.len > 0:
            firstLine = line
            break
    if firstLine.len == 0:
        return "Untitled"
    if firstLine.runeLen <= maxChars:
        return firstLine
    firstLine.runeSubStr(0, maxChars).strip(leading = false, trailing = true) & "…"

func buildPreview(content: string, previewChars: int): string =
    if content.runeLen <= previewChars:
        return content
    content.runeSubStr(0, previewChars) &
        "\n\n… (truncated — open the raw view for the full content)"

proc createPasteRecord*(cfg: AppConfig, title, content, visibilityIn, ownerIp: string): Paste =
    ## Shared paste-creation pipeline. Raises PayloadTooLargeError (-> 413) on oversize/over-quota.
    let id = generateId()
    let ttl = if title.strip().len == 0: deriveTitle(content, cfg.untitledTitleMaxChars)
              else: title.strip()
    let byteCount = content.len.int64   # Nim strings are bytes => UTF-8 byte count
    let visibility = if visibilityIn == "private": "private" else: "public"

    if byteCount > cfg.maxPasteBytes:
        raise newException(PayloadTooLargeError,
            &"Paste size exceeds the maximum allowed size of {cfg.maxPasteBytes div (1024*1024)}MB")

    ensureWithinQuota(ownerIp, byteCount, cfg.maxStorageBytesPerIp)

    var p = Paste(id: id, title: ttl, size: byteCount, visibility: visibility, createdAt: nowIso())
    if byteCount <= cfg.inlinePasteMaxBytes:
        p.content = content
        p.isTruncated = false
        p.blobId = ""
    else:
        let (blobId, size) = saveFromString(content)
        p.content = buildPreview(content, cfg.pastePreviewChars)
        p.size = size
        p.isTruncated = true
        p.blobId = blobId

    insertPaste(p, ownerIp)
    notifyPasteCreated(p)
    p

proc handleCreatePaste*(ctx: Ctx) =
    var root: JsonNode
    try:
        root = parseJson(ctx.req.bodyString())
    except CatchableError:
        ctx.respondError(400, "Invalid request body")
        return
    let content = root{"content"}.getStr("")
    if content.strip().len == 0:
        ctx.respondError(400, "Content cannot be empty")
        return
    if ctx.rejectPasteLimit(checkPasteCreate(ctx.ip)): return
    let title = root{"title"}.getStr("")
    let visibility = root{"visibility"}.getStr("public")
    try:
        let p = createPasteRecord(ctx.cfg, title, content, visibility, ctx.ip)
        ctx.req.respond(200, $(%*{"id": p.id}))
    except PayloadTooLargeError as e:
        ctx.respondError(413, e.msg)
