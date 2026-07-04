## File upload service, mirroring pastebin-api/services/FileUploadService.cs.
##
## Single-file uploads STREAM from the spilled request body straight into a blob (flat memory).
## Folder uploads are zipped: this path stages entry contents in memory via zippy (bounded by
## the 100 MB per-IP quota) — a candidate for a streaming zip writer later. Marked LIMITATION.

import std/[options, strutils, tables, strformat]
import config, types, db, blobstore, quota, ntfy, timeutil, apperrors, multipart
import zippy/ziparchives

proc generateFileId(): string =
    ## First 12 hex chars of a GUID-N equivalent (6 random bytes -> 12 hex).
    randomHex(6)

proc persist(f: StoredFile, ownerIp: string) =
    insertFile(f, ownerIp)
    notifyFileUploaded(f)

func normalizeVisibility(v: string): string =
    ## "private" stays private (unlisted); anything else defaults to public. Mirrors createPaste.
    if v == "private": "private" else: "public"

proc uploadFile*(cfg: AppConfig, entry: MultipartEntry, ownerIp, visibility: string): StoredFile =
    ## entry is a file part whose bytes are on disk at entry.dataFilePath.
    if entry.size > cfg.maxRequestBytes:
        raise newException(PayloadTooLargeError,
            &"File size exceeds the maximum allowed size of {cfg.maxRequestBytes div (1024*1024)}MB")

    ensureWithinQuota(ownerIp, entry.size, cfg.maxStorageBytesPerIp)

    let (blobId, size) = saveFromFile(entry.dataFilePath)
    result = StoredFile(
        id: generateFileId(),
        originalName: entry.filename,
        contentType: (if entry.contentType.len == 0: "application/octet-stream" else: entry.contentType),
        size: size,
        uploadedAt: nowIso(),
        visibility: normalizeVisibility(visibility),
        blobId: blobId)
    persist(result, ownerIp)

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

proc uploadFolder*(cfg: AppConfig, files: seq[MultipartEntry], folderName, ownerIp, visibility: string): StoredFile =
    if files.len == 0:
        raise newException(PayloadTooLargeError, "No files provided")

    var uncompressedTotal: int64 = 0
    for e in files: uncompressedTotal += e.size
    if uncompressedTotal > cfg.maxRequestBytes:
        raise newException(PayloadTooLargeError,
            &"Folder size exceeds the maximum allowed size of {cfg.maxRequestBytes div (1024*1024)}MB")

    ensureWithinQuota(ownerIp, uncompressedTotal, cfg.maxStorageBytesPerIp)

    # LIMITATION: zippy has no streaming zip writer, so entry contents are read into memory
    # here. Bounded by the 100 MB per-IP quota reserved just above; revisit with a streaming
    # writer if folder uploads grow. Single-file uploads (the common path) fully stream.
    var entries: OrderedTable[string, string]
    for e in files:
        entries[zipEntryName(e)] = readFile(e.dataFilePath)
    let zipBytes = createZipArchive(entries)
    let (blobId, size) = saveFromString(zipBytes)

    result = StoredFile(
        id: generateFileId(),
        originalName: zipFileName(folderName),
        contentType: "application/zip",
        size: size,
        uploadedAt: nowIso(),
        visibility: normalizeVisibility(visibility),
        blobId: blobId)
    persist(result, ownerIp)

proc getFile*(fileId: string): Option[StoredFile] =
    selectFile(fileId)

proc downloadFile*(fileId: string): Option[DownloadData] =
    let fo = getFile(fileId)
    if fo.isNone: return none(DownloadData)
    let f = fo.get
    if f.blobId.len == 0 or not blobExists(f.blobId): return none(DownloadData)
    some(DownloadData(kind: dkBlob, blobPath: blobPath(f.blobId),
        contentType: f.contentType, fileName: f.originalName))

proc deleteFile*(fileId: string): bool =
    let fo = getFile(fileId)
    if fo.isNone: return false
    let f = fo.get
    if f.blobId.len > 0:
        discard deleteBlob(f.blobId)
    deleteFileRow(fileId)
