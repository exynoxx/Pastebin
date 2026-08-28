## Write queue: new pastes are held in RAM and persisted by a background thread, so POST /api/pastes
## returns as soon as the id exists.
##
## `enqueue` holds the full content and returns at once; the persister drains the channel and writes
## blob + SQLite row, then drops the pending entry. Over `maxBytes` of unwritten content, enqueue
## returns false and the caller responds 429 — there is no synchronous fallback. A paste is lost if
## the box crashes between enqueue and the write (accepted, same as the access log).
##
## Concurrency: one process-wide Lock guards the pending table. A Pending's fields are immutable
## after enqueue, so /raw can read `content` without the lock.

import std/[locks, tables]
import types
import common/templates
referencing blobstore
referencing db

type
  Pending* = ref object
    ## An accepted-but-unwritten paste. Immutable once enqueued.
    paste: Paste
    content*: string           ## full text (what /raw serves until the blob exists)
    ownerIp: string

var
  gLock: Lock
  gPending: Table[string, Pending]
  gBytes, gMaxBytes: int64             ## unwritten content resident in RAM, vs its cap
  gQueue: Channel[string]              ## ids awaiting persistence
  gPersister: Thread[void]

initLock(gLock)
gQueue.open()

proc finish(id: string): bool
proc persistLoop() {.thread.}

proc initWriteQueue*(maxBytes: int64) =
  withLock gLock:
    gMaxBytes = maxBytes
  createThread(gPersister, persistLoop)

proc resetForTest*(maxBytes: int64) =
  ## Test-only reset — empty, given budget, no persister.
  withLock gLock:
    gPending = initTable[string, Pending]()
    gBytes = 0
    gMaxBytes = maxBytes

proc enqueue*(p: Paste, fullContent, ownerIp: string): bool =
  ## Queue a paste for persistence; false when too much unwritten content is already resident
  ## (nothing can be dropped to make room — it isn't on disk yet).
  let cost = fullContent.len.int64
  withLock gLock:
    if gBytes + cost > gMaxBytes: return false
    gPending[p.id] = Pending(paste: p, content: fullContent, ownerIp: ownerIp)
    gBytes += cost
  gQueue.send(p.id)
  true

proc pending*(id: string): Pending =
  ## The unwritten paste, or nil once it is on disk (or was never queued).
  withLock gLock:
    result = gPending.getOrDefault(id)

proc cancel*(id: string): bool =
  ## Admin delete: drop a paste before it is written. True if it was still pending. A write already
  ## in flight is rolled back by the persister, whose `finish` then finds nothing.
  finish(id)

# ---- private helpers --------------------------------------------------------

proc finish(id: string): bool =
  ## Drop the pending entry, releasing its bytes. False if it was already cancelled.
  var e: Pending
  withLock gLock:
    if not gPending.pop(id, e): return false
    gBytes -= e.content.len.int64
    return true

proc persistLoop() {.thread.} =
  ## Drain the queue: write blob (large pastes only) + DB row, then drop the pending copy.
  {.cast(gcsafe).}:
    while true:
      let id = gQueue.recv()
      let e = pending(id)
      if e == nil: continue                      # cancelled before we got to it; nothing written
      var stored = e.paste
      try:
        if stored.isTruncated:
          let (bid, _) = blobstore.saveFromString(e.content)
          stored.blobId = bid
        db.insertPaste(stored, e.ownerIp)
      except CatchableError:
        # Write failed: drop the pending copy (paste lost) + clean any orphan blob.
        if stored.blobId.len > 0: discard blobstore.deleteBlob(stored.blobId)
        discard finish(id)
        continue
      if not finish(id):
        # Cancelled mid-write: roll back so no orphan row/blob is left.
        discard db.deletePasteRow(id)
        if stored.blobId.len > 0: discard blobstore.deleteBlob(stored.blobId)
