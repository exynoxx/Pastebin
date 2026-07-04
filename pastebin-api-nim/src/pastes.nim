## Paste service, mirroring pastebin-api/services/PasteService.cs.

import std/[options, strutils, unicode, sysrand, strformat]
import config, types, db, blobstore, quota, ntfy, timeutil, apperrors

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

proc createPaste*(cfg: AppConfig, title, content, visibilityIn, ownerIp: string): Paste =
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

proc getPaste*(id: string): Option[Paste] =
    selectPaste(id)

proc getRecentPastes*(limit: int): seq[PasteSummary] =
    selectRecentSummaries(limit)

proc listAllPastes*(): seq[AdminPasteRow] =
    ## Admin: every paste regardless of visibility, newest first.
    selectAllPastes()

proc deletePaste*(id: string): bool =
    ## Admin: remove a paste and its backing blob (if any). Mirrors files.deleteFile.
    let po = getPaste(id)
    if po.isNone: return false
    let p = po.get
    if p.blobId.len > 0:
        discard deleteBlob(p.blobId)
    deletePasteRow(id)

proc openRaw*(id: string): Option[DownloadData] =
    let po = getPaste(id)
    if po.isNone: return none(DownloadData)
    let p = po.get
    if p.blobId.len > 0 and blobExists(p.blobId):
        return some(DownloadData(kind: dkBlob, blobPath: blobPath(p.blobId),
            contentType: "text/plain; charset=utf-8", fileName: p.id & ".txt"))
    return some(DownloadData(kind: dkInline, inlineData: p.content,
        contentType: "text/plain; charset=utf-8", fileName: p.id & ".txt"))
