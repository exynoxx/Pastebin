## POST /api/pastes — create an inline/blob paste from a JSON body.
##
## `createPasteRecord` — the size-check → quota → inline-vs-blob → persist → notify pipeline — is
## the one bit of paste logic shared with the create-paste-from-file slice, so it is exported here
## (its canonical home) rather than living in a separate service layer.

import std/[json, strutils, unicode]
import ../routes
import ../../types, ../../apperrors
referencing quota
referencing ntfy
referencing timeutil
referencing ids
referencing pastecache

const
    PastePreviewChars = 8_192      ## chars kept in the stored inline preview of a large paste
    UntitledTitleMaxChars = 40     ## cap on a title auto-derived from the first content line

func deriveTitle(content: string, maxChars: int): string
func buildPreview(content: string, previewChars: int): string

proc createPasteRecord*(cfg: AppConfig, title, content, visibilityIn, ownerIp: string): Paste =
    ## Shared paste-creation pipeline. Raises PayloadTooLargeError (-> 413) when over the per-IP quota.
    ## Keeps the full content in RAM and returns immediately; a background thread persists it. Raises
    ## CacheFullError (-> 429) when the cache can't admit the paste (server at capacity).
    ## Paste content is bounded only by the global request cap (maxRequestBytes), not a per-paste limit.
    let id = ids.newId()
    let ttl = if title.strip().len == 0: deriveTitle(content, UntitledTitleMaxChars)
              else: title.strip()
    let byteCount = content.len.int64   # Nim strings are bytes => UTF-8 byte count
    let visibility = types.normalizeVisibility(visibilityIn)

    quota.ensureWithinQuota(ownerIp, byteCount, cfg.maxStorageBytesPerIp)

    # Build the display/stored shape. For large pastes the blob is written later by the persister, so
    # blobId stays "" here.
    var p = Paste(id: id, title: ttl, size: byteCount, visibility: visibility, createdAt: timeutil.nowMillis())
    if byteCount <= cfg.inlinePasteMaxBytes:
        p.content = content
        p.isTruncated = false
        p.blobId = BlobId("")
    else:
        p.content = buildPreview(content, PastePreviewChars)
        p.isTruncated = true
        p.blobId = BlobId("")

    # Admit the full content to RAM; the background persister is the only store path now. A failed
    # admit means the cache is at capacity (all remaining bytes are pinned-dirty) -> shed with 429.
    if not pastecache.admit(p, content, ownerIp):
        raise newException(CacheFullError, "Server is at capacity. Please retry shortly.")
    ntfy.notifyPasteCreated(p)
    p

proc handleCreatePaste*(ctx: Ctx) =
    # No per-paste size limit: the body is already bounded by the global request cap (maxRequestBytes,
    # ~51 MB), enforced by the framework before this handler runs, so it can't grow unbounded here.
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
