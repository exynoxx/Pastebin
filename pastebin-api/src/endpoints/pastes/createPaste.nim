## POST /api/pastes — create an inline/blob paste from a JSON body.
##
## `createPasteRecord` — the size-check → quota → inline-vs-blob → persist → notify pipeline — is
## the one bit of paste logic shared with the create-paste-from-file slice, so it is exported here
## (its canonical home) rather than living in a separate service layer.

import std/[json, strutils, unicode, strformat]
import ../routes
import ../../types, ../../apperrors
importuse quota
importuse ntfy
importuse timeutil
importuse ids
importuse pastecache

func deriveTitle(content: string, maxChars: int): string
func buildPreview(content: string, previewChars: int): string

proc createPasteRecord*(cfg: AppConfig, title, content, visibilityIn, ownerIp: string): Paste =
    ## Shared paste-creation pipeline. Raises PayloadTooLargeError (-> 413) on oversize/over-quota.
    ## Keeps the full content in RAM and returns immediately; a background thread persists it. Raises
    ## CacheFullError (-> 429) when the cache can't admit the paste (server at capacity).
    let id = ids.newId()
    let ttl = if title.strip().len == 0: deriveTitle(content, cfg.untitledTitleMaxChars)
              else: title.strip()
    let byteCount = content.len.int64   # Nim strings are bytes => UTF-8 byte count
    let visibility = types.normalizeVisibility(visibilityIn)

    if byteCount > cfg.maxPasteBytes:
        raise newException(PayloadTooLargeError,
            &"Paste size exceeds the maximum allowed size of {cfg.maxPasteBytes div (1024*1024)}MB")

    quota.ensureWithinQuota(ownerIp, byteCount, cfg.maxStorageBytesPerIp)

    # Build the display/stored shape. For large pastes the blob is written later by the persister, so
    # blobId stays "" here.
    var p = Paste(id: id, title: ttl, size: byteCount, visibility: visibility, createdAt: timeutil.nowMillis())
    if byteCount <= cfg.inlinePasteMaxBytes:
        p.content = content
        p.isTruncated = false
        p.blobId = BlobId("")
    else:
        p.content = buildPreview(content, cfg.pastePreviewChars)
        p.isTruncated = true
        p.blobId = BlobId("")

    # Admit the full content to RAM; the background persister is the only store path now. A failed
    # admit means the cache is at capacity (all remaining bytes are pinned-dirty) -> shed with 429.
    if not pastecache.admit(p, content, ownerIp):
        raise newException(CacheFullError, "Server is at capacity. Please retry shortly.")
    ntfy.notifyPasteCreated(p)
    p

proc handleCreatePaste*(ctx: Ctx) =
    # Bound the body BEFORE it's read into a string and parsed into a node tree — otherwise a
    # multi-hundred-MB JSON POST (allowed by the 1 GB MAX_REQUEST_BYTES) is fully materialised and
    # parsed before the maxPasteBytes check in createPasteRecord, blowing the container memory cap.
    # The cap leaves generous headroom over maxPasteBytes for the JSON envelope + string escaping,
    # so a legitimate max-size paste is never rejected here (the exact content check runs later).
    if ctx.req.bodyLen > ctx.cfg.maxPasteBytes * 2 + 65_536:
        ctx.respondError(413,
            "Paste size exceeds the maximum allowed size of " &
            $(ctx.cfg.maxPasteBytes div (1024*1024)) & "MB")
        return
    let root = parseJsonBodyOr400(ctx)
    let content = root{"content"}.getStr("")
    if content.strip().len == 0:
        ctx.respondError(400, "Content cannot be empty")
        return
    let title = root{"title"}.getStr("")
    let visibility = root{"visibility"}.getStr("public")
    try:
        let p = createPasteRecord(ctx.cfg, title, content, visibility, ctx.ip)
        ctx.req.respond(200, $(%*{"id": p.id}))
    except PayloadTooLargeError as e:
        ctx.respondError(413, e.msg)
    except CacheFullError as e:
        ctx.req.respond(429, errorJson(e.msg), extraHeaders = [("Retry-After", "5")])

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
