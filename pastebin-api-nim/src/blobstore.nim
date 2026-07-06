## Filesystem blob store, mirroring pastebin-api/services/BlobStore.cs.
##
## blobId = 32-char lowercase hex (GUID "N" equivalent). Two-char sharding keeps any single
## directory small. Writes go to "<final>.tmp" then rename → publish atomically so an aborted
## upload never leaves a half-written blob. Copies stream in bounded chunks (flat memory).

import std/[os, sysrand]

var gRoot: string

proc initBlobStore*(root: string) =
    gRoot = root
    createDir(root)

proc randomHex*(byteCount: int): string =
    ## `byteCount` CSPRNG bytes rendered as lowercase hex (2 chars per byte).
    let bytes = urandom(byteCount)
    const hexChars = "0123456789abcdef"
    result = newStringOfCap(byteCount * 2)
    for b in bytes:
        result.add hexChars[int(b shr 4)]
        result.add hexChars[int(b and 0x0f)]

proc newBlobId*(): string =
    ## 16 random bytes -> 32 lowercase hex chars (like Guid.NewGuid().ToString("N")).
    randomHex(16)

proc pathFor(blobId: string, ensureDir = false): string =
    let shard = if blobId.len >= 2: blobId[0 .. 1] else: "00"
    let dir = gRoot / shard
    if ensureDir: createDir(dir)
    dir / blobId

proc blobPath*(blobId: string): string = pathFor(blobId)
proc blobExists*(blobId: string): bool = fileExists(pathFor(blobId))

proc deleteBlob*(blobId: string): bool =
    let p = pathFor(blobId)
    if not fileExists(p): return false
    removeFile(p)
    true

proc saveFromString*(data: string): tuple[blobId: string, size: int64] =
    ## Store an in-memory buffer (large-paste content, staged zip already on disk uses saveFromFile).
    let blobId = newBlobId()
    let finalPath = pathFor(blobId, ensureDir = true)
    let tmpPath = finalPath & ".tmp"
    writeFile(tmpPath, data)
    moveFile(tmpPath, finalPath) # same dir => atomic rename
    (blobId, data.len.int64)

proc saveFromFile*(srcPath: string): tuple[blobId: string, size: int64] =
    ## Stream an existing file (e.g. the spilled request body or a staged zip) into a new blob.
    ## copyFile streams in bounded chunks internally, so memory stays flat regardless of size.
    let blobId = newBlobId()
    let finalPath = pathFor(blobId, ensureDir = true)
    let tmpPath = finalPath & ".tmp"
    copyFile(srcPath, tmpPath)
    let total = getFileSize(tmpPath)
    moveFile(tmpPath, finalPath)
    (blobId, total)
