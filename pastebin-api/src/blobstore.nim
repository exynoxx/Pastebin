## Filesystem blob store.
##
## blobId = 32-char lowercase hex. Two-char sharding keeps any single
## directory small. Writes go to "<final>.tmp" then rename → publish atomically so an aborted
## upload never leaves a half-written blob. Copies stream in bounded chunks (flat memory).

import std/[os, strutils, sysrand]
import types

var gRoot: string

proc initBlobStore*(root: string) =
    gRoot = root
    createDir(root)

proc newBlobId*(): BlobId =
    ## 16 CSPRNG bytes -> 32 lowercase hex chars.
    var buf = newString(16)
    doAssert urandom(buf.toOpenArrayByte(0, buf.high)), "CSPRNG unavailable"
    BlobId(buf.toHex.toLowerAscii)

proc pathFor(blobId: BlobId, ensureDir = false): string =
    let s = blobId.string
    let shard = if s.len >= 2: s[0 .. 1] else: "00"
    let dir = gRoot / shard
    if ensureDir: createDir(dir)
    dir / s

proc blobPath*(blobId: BlobId): string = pathFor(blobId)
proc blobExists*(blobId: BlobId): bool = fileExists(pathFor(blobId))

proc deleteBlob*(blobId: BlobId): bool =
    let p = pathFor(blobId)
    if not fileExists(p): return false
    removeFile(p)
    true

proc saveFromString*(data: string): tuple[blobId: BlobId, size: int64] =
    ## Store an in-memory buffer (large-paste content, staged zip already on disk uses saveFromFile).
    let blobId = newBlobId()
    let finalPath = pathFor(blobId, ensureDir = true)
    let tmpPath = finalPath & ".tmp"
    writeFile(tmpPath, data)
    moveFile(tmpPath, finalPath) # same dir => atomic rename
    (blobId, data.len.int64)

proc saveFromFile*(srcPath: string): tuple[blobId: BlobId, size: int64] =
    ## Stream an existing file (e.g. the spilled request body or a staged zip) into a new blob.
    ## copyFile streams in bounded chunks internally, so memory stays flat regardless of size.
    let blobId = newBlobId()
    let finalPath = pathFor(blobId, ensureDir = true)
    let tmpPath = finalPath & ".tmp"
    copyFile(srcPath, tmpPath)
    let total = getFileSize(tmpPath)
    moveFile(tmpPath, finalPath)
    (blobId, total)
