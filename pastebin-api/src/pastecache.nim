## In-memory paste cache: a size-bounded LRU that serves reads and buffers not-yet-persisted writes.
## admit() holds a new paste in RAM and returns its id at once; a background persister thread drains
## it to db + blobstore, after which the entry lives on as a clean, evictable read-cache entry. When
## a paste won't fit, admit() returns false and the caller responds 429. A paste is lost if
## the box crashes between admit() and the flush (accepted, same as the access log).
##
## Concurrency: one process-wide Lock guards everything; Lru itself is not thread-safe. Entry content
## is immutable after admit, so /raw can borrow it (CachedRawView) and read it without the lock.

import std/[locks, tables, options]
import types, config
import common/templates
importuse blobstore
importuse db

type
  CacheEntry = ref object
    id, title, ownerIp: string
    size, createdAt: int64
    visibility: Visibility
    isTruncated: bool            ## large paste => display uses previewContent
    previewContent: string       ## display text for large pastes ("" when inline)
    fullContent: string          ## full text (raw serving + persister)
    blobId: BlobId               ## "" until the persister writes the blob
    dirty: bool                  ## not yet persisted; pinned (un-evictable)
    bytes: int64                 ## budget cost = fullContent.len
    prev, next: CacheEntry       ## LRU links; head = MRU, tail = LRU

  CachedRawView* = object
    ## Borrowed /raw handle: `entry` keeps the immutable content alive; dirty/blobId are snapshotted.
    dirty*: bool
    blobId*: BlobId
    entry: CacheEntry

# ---- Lru: size-bounded intrusive LRU + index --------------------------------
# id -> entry index over a doubly-linked recency list, tracking resident bytes vs a budget.
# Dirty entries are pinned. Not thread-safe: the module serializes every call under gLock.

type
  Lru = object
    table: Table[string, CacheEntry]
    head, tail: CacheEntry               ## MRU / LRU ends
    bytes: int64                         ## total resident (dirty + clean)
    maxBytes: int64

proc unlink(lru: var Lru, e: CacheEntry) =
  if e.prev != nil: e.prev.next = e.next else: lru.head = e.next
  if e.next != nil: e.next.prev = e.prev else: lru.tail = e.prev
  e.prev = nil
  e.next = nil

proc pushFront(lru: var Lru, e: CacheEntry) =
  e.prev = nil
  e.next = lru.head
  if lru.head != nil: lru.head.prev = e
  lru.head = e
  if lru.tail == nil: lru.tail = e

proc get(lru: Lru, id: string): CacheEntry =
  ## Lookup, no LRU reorder. nil if absent.
  if lru.table.hasKey(id): lru.table[id] else: nil

proc touch(lru: var Lru, e: CacheEntry) =
  ## Move to MRU (no-op if already there).
  returnif: lru.head == e
  lru.unlink(e)
  lru.pushFront(e)

proc admit(lru: var Lru, e: CacheEntry) =
  lru.table[e.id] = e
  lru.pushFront(e)
  lru.bytes += e.bytes

proc remove(lru: var Lru, e: CacheEntry) =
  lru.unlink(e)
  lru.table.del(e.id)
  lru.bytes -= e.bytes

proc fits(lru: Lru, cost: int64): bool =
  lru.bytes + cost <= lru.maxBytes

proc evictCleanToFit(lru: var Lru, cost: int64) =
  ## Drop clean entries from the LRU end until `cost` fits; walks past pinned dirty ones.
  var e = lru.tail
  while e != nil and not lru.fits(cost):
    let prev = e.prev
    if not e.dirty: lru.remove(e)
    e = prev

proc reset(lru: var Lru, maxBytes: int64) =
  ## Empty + rebudget. Unlink every node first so atomicArc (no cycle GC) can't leak the list.
  var e = lru.head
  while e != nil:
    let nxt = e.next
    e.prev = nil
    e.next = nil
    e = nxt
  lru.head = nil
  lru.tail = nil
  lru.table = initTable[string, CacheEntry]()
  lru.bytes = 0
  lru.maxBytes = maxBytes

# ---- module state -----------------------------------------------------------

var
  gLock: Lock
  gLru: Lru
  gQueue: Channel[string]              ## ids awaiting background persistence
  gPersister: Thread[void]

initLock(gLock)                        ## process-wide lock + queue, init once at load
gQueue.open()                          ## unbounded; drained by the persister when enabled

# Private helpers, declared before use.
func toPaste(e: CacheEntry): Paste
proc snapshotForPersist(id: string): CacheEntry
proc persistLoop() {.thread.}

# ---- public API -------------------------------------------------------------

proc initPasteCache*(cfg: AppConfig) =
  ## Size the cache and start the background persister.
  gLru.reset(cfg.cacheMaxBytes)
  createThread(gPersister, persistLoop)

proc resetForTest*(maxBytes: int64) =
  ## Test-only reset — empty, given budget, no persister.
  withLock gLock:
    gLru.reset(maxBytes)

proc admit*(display: Paste, fullContent, ownerIp: string): bool =
  ## Admit a new paste as a dirty entry; false if it won't fit even after evicting all clean entries.
  let cost = fullContent.len.int64
  withLock gLock:
    if cost > gLru.maxBytes: return false
    gLru.evictCleanToFit(cost)
    if not gLru.fits(cost): return false   # only dirty bytes remain; can't make room
    let e = CacheEntry(
      id: display.id, title: display.title, ownerIp: ownerIp,
      size: display.size, createdAt: display.createdAt, visibility: display.visibility,
      isTruncated: display.isTruncated,
      previewContent: (if display.isTruncated: display.content else: ""),
      fullContent: fullContent,
      blobId: BlobId(""), dirty: true, bytes: cost)
    gLru.admit(e)
    gQueue.send(e.id)
    return true

proc getDisplayPaste*(id: string): Option[Paste] =
  ## GET /api/pastes/{id}: metadata + inline/preview content. Touches LRU.
  withLock gLock:
    let e = gLru.get(id)
    if e == nil: return none(Paste)
    gLru.touch(e)
    result = some(e.toPaste())

proc acquireForRaw*(id: string): Option[CachedRawView] =
  ## GET /{id}/raw: snapshot dirty/blobId under the lock; caller reads content lock-free (immutable).
  withLock gLock:
    let e = gLru.get(id)
    if e == nil: return none(CachedRawView)
    gLru.touch(e)
    result = some(CachedRawView(dirty: e.dirty, blobId: e.blobId, entry: e))

func content*(v: CachedRawView): lent string = v.entry.fullContent

proc markPersisted*(id: string, blobId: BlobId): bool =
  ## Persister callback: flip dirty->clean, record blobId. false if the entry was deleted mid-flight
  ## (caller then rolls back the row/blob it wrote).
  withLock gLock:
    let e = gLru.get(id)
    if e == nil: return false
    e.dirty = false
    e.blobId = blobId
    return true

proc removeFromCache*(id: string): tuple[wasCached: bool, blobId: BlobId] =
  ## Admin delete: evict + report blobId ("" if inline/unflushed) so the caller can delete the blob.
  withLock gLock:
    let e = gLru.get(id)
    if e == nil: return (false, BlobId(""))
    let bid = e.blobId
    gLru.remove(e)
    return (true, bid)

# ---- private helpers --------------------------------------------------------

func toPaste(e: CacheEntry): Paste =
  ## entry -> domain Paste; blobId "" while still dirty.
  Paste(
    id: e.id, title: e.title, size: e.size, createdAt: e.createdAt,
    visibility: e.visibility, isTruncated: e.isTruncated, blobId: e.blobId,
    content: (if e.isTruncated: e.previewContent else: e.fullContent))

proc snapshotForPersist(id: string): CacheEntry =
  ## Entry ref for the persister, or nil if already deleted (a dirty entry can't be evicted).
  withLock gLock:
    result = gLru.get(id)

proc persistLoop() {.thread.} =
  ## Drain the queue: write blob (large only) + DB row, then mark clean. Roll back if deleted mid-write.
  {.cast(gcsafe).}:
    while true:
      let id = gQueue.recv()
      let e = snapshotForPersist(id)
      if e == nil: continue                      # deleted before flush; nothing written
      var written = BlobId("")
      var stored = e.toPaste()                   # blobId set below once the blob is written
      try:
        if e.isTruncated:
          let (bid, _) = blobstore.saveFromString(e.fullContent)
          written = bid
          stored.blobId = bid
        db.insertPaste(stored, e.ownerIp)
      except CatchableError:
        # Persist failed: drop the cached copy (paste lost) + clean any orphan blob.
        if written.len > 0: discard blobstore.deleteBlob(written)
        discard removeFromCache(id)
        continue
      if not markPersisted(id, written):
        # Deleted mid-write: roll back so no orphan row/blob is left.
        discard db.deletePasteRow(id)
        if written.len > 0: discard blobstore.deleteBlob(written)
