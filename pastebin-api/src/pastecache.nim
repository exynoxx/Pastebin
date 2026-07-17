## In-memory paste cache: a size-bounded LRU that serves reads and buffers not-yet-persisted
## writes. Newly created pastes are admitted here (full content in RAM) and their id returned
## immediately; a background persister thread (see Task 3 / initPasteCache) drains the write queue
## to db.nim + blobstore.nim. After a paste is persisted its entry stays as a clean LRU read-cache
## entry until evicted. When a paste would not fit the budget, tryAdmit returns false and the caller
## persists synchronously instead.
##
## Concurrency: one process-wide Lock guards the table, the intrusive LRU list, and all counters
## (mirrors accesslog.nim / ratelimit.nim). Entry content is immutable after admit, so raw serving
## can borrow it via a ref (CachedRawView) without copying under the lock. Dirty entries are pinned
## (never evicted); only clean entries are LRU-evictable.

import std/[locks, tables, options]
import types, config, db, blobstore, macros

type
  CacheEntry = ref object
    id, title, ownerIp: string
    size, createdAt: int64
    visibility: Visibility
    isTruncated: bool            ## true => large paste; display uses previewContent
    previewContent: string       ## display text for large pastes; "" for inline (use fullContent)
    fullContent: string          ## full text (raw serving + persister)
    blobId: BlobId                ## "" until the persister writes the blob (large pastes)
    dirty: bool                  ## true => not yet on disk/DB; un-evictable
    bytes: int64                 ## budget cost = fullContent.len
    prev, next: CacheEntry       ## LRU links; gHead = MRU, gTail = LRU

  CachedRawView* = object
    ## A borrowed handle for /raw: `entry` keeps the (immutable) content alive; dirty/blobId are
    ## snapshotted under the lock so the caller never races the persister on those fields.
    dirty*: bool
    blobId*: BlobId
    entry: CacheEntry

var
  gLock: Lock
  gInited: bool
  gEnabled: bool
  gMaxBytes: int64
  gBytes: int64                        ## total resident (dirty + clean)
  gDirtyBytes: int64                   ## bytes pinned by not-yet-persisted entries
  gTable: Table[string, CacheEntry]
  gPendingByIp: Table[string, int64]
  gHead, gTail: CacheEntry             ## MRU / LRU ends of the doubly-linked list
  gQueue: Channel[string]              ## ids awaiting background persistence
  gPersister: Thread[void]
  gPersisterStarted: bool

# Private helpers declared before use (public API reads first).
proc unlink(e: CacheEntry)
proc pushFront(e: CacheEntry)
proc touch(e: CacheEntry)
proc evictOne(e: CacheEntry)
proc evictCleanToFit(cost: int64)
proc addPending(ownerIp: string, delta: int64)
proc clearEntries()
proc persistLoop() {.thread.}
proc snapshotForPersist(id: string): CacheEntry

# ---- public API ------------------------------------------------------------

proc cacheEnabled*(): bool = gEnabled

proc initPasteCache*(cfg: AppConfig) =
  ## Production init: configure the singleton and start the background persister. When the cache is
  ## disabled, tryAdmit short-circuits to false and every create persists synchronously.
  if not gInited:
    initLock(gLock)
    gInited = true
  gEnabled = cfg.pasteCacheEnabled
  gMaxBytes = cfg.cacheMaxBytes
  gBytes = 0
  gDirtyBytes = 0
  clearEntries()
  gTable = initTable[string, CacheEntry]()
  gPendingByIp = initTable[string, int64]()
  returnif(not gEnabled)
  gQueue.open()
  gPersisterStarted = true
  createThread(gPersister, persistLoop)

proc resetForTest*(maxBytes: int64) =
  ## Test-only: (re)initialize the singleton — enabled, empty, given budget. No persister thread.
  if not gInited:
    initLock(gLock)
    gInited = true
  withLock gLock:
    gEnabled = true
    gMaxBytes = maxBytes
    gBytes = 0
    gDirtyBytes = 0
    clearEntries()
    gTable = initTable[string, CacheEntry]()
    gPendingByIp = initTable[string, int64]()

proc pendingBytesForOwner*(ownerIp: string): int64 =
  returnif(not gEnabled, 0)
  withLock gLock:
    result = gPendingByIp.getOrDefault(ownerIp, 0)

proc tryAdmit*(display: Paste, fullContent, ownerIp: string): bool =
  ## Admit a new paste to the cache as a dirty entry. Returns false (caller persists synchronously)
  ## when the cache is disabled or the paste cannot fit even after evicting all clean entries.
  returnif(not gEnabled, false)
  let cost = fullContent.len.int64
  withLock gLock:
    returnif(cost > gMaxBytes, false)
    evictCleanToFit(cost)
    returnif(gBytes + cost > gMaxBytes, false)   # only dirty bytes remain; cannot make room
    let e = CacheEntry(
      id: display.id, title: display.title, ownerIp: ownerIp,
      size: display.size, createdAt: display.createdAt, visibility: display.visibility,
      isTruncated: display.isTruncated,
      previewContent: (if display.isTruncated: display.content else: ""),
      fullContent: fullContent,
      blobId: BlobId(""), dirty: true, bytes: cost)
    gTable[e.id] = e
    pushFront(e)
    gBytes += cost
    gDirtyBytes += cost
    addPending(ownerIp, cost)
    if gPersisterStarted: gQueue.send(e.id)
    return true

proc getDisplayPaste*(id: string): Option[Paste] =
  ## Cache read for GET /api/pastes/{id}. Touches LRU. content = full (inline) or preview (large).
  returnif(not gEnabled, none(Paste))
  withLock gLock:
    returnif(not gTable.hasKey(id), none(Paste))
    let e = gTable[id]
    touch(e)
    result = some(Paste(
      id: e.id, title: e.title, size: e.size, createdAt: e.createdAt,
      visibility: e.visibility, isTruncated: e.isTruncated, blobId: e.blobId,
      content: (if e.isTruncated: e.previewContent else: e.fullContent)))

proc acquireForRaw*(id: string): Option[CachedRawView] =
  ## Cache read for GET /api/pastes/{id}/raw. Touches LRU; snapshots dirty/blobId under the lock and
  ## returns a handle whose content the caller reads WITHOUT the lock (content is immutable).
  returnif(not gEnabled, none(CachedRawView))
  withLock gLock:
    returnif(not gTable.hasKey(id), none(CachedRawView))
    let e = gTable[id]
    touch(e)
    result = some(CachedRawView(dirty: e.dirty, blobId: e.blobId, entry: e))

proc content*(v: CachedRawView): lent string = v.entry.fullContent

proc markPersisted*(id: string, blobId: BlobId): bool =
  ## Called by the persister after a successful blob+DB write: flip dirty->clean, record blobId,
  ## release the pending-bytes reservation. Returns false if the entry is gone (deleted mid-flight),
  ## in which case the caller must roll back the row/blob it just wrote.
  returnif(not gEnabled, false)
  withLock gLock:
    returnif(not gTable.hasKey(id), false)
    let e = gTable[id]
    if e.dirty:
      e.dirty = false
      gDirtyBytes -= e.bytes
      addPending(e.ownerIp, -e.bytes)
    e.blobId = blobId
    return true

proc removeFromCache*(id: string): tuple[wasCached: bool, blobId: BlobId] =
  ## Evict an entry (admin delete). Returns whether it was cached and its blobId ("" if inline or
  ## not-yet-flushed) so the caller can delete the on-disk blob if one exists.
  returnif(not gEnabled, (false, BlobId("")))
  withLock gLock:
    returnif(not gTable.hasKey(id), (false, BlobId("")))
    let e = gTable[id]
    let bid = e.blobId
    if e.dirty:
      gDirtyBytes -= e.bytes
      addPending(e.ownerIp, -e.bytes)
    unlink(e)
    gTable.del(id)
    gBytes -= e.bytes
    return (true, bid)

# ---- private helpers -------------------------------------------------------

proc unlink(e: CacheEntry) =
  if e.prev != nil: e.prev.next = e.next else: gHead = e.next
  if e.next != nil: e.next.prev = e.prev else: gTail = e.prev
  e.prev = nil
  e.next = nil

proc pushFront(e: CacheEntry) =
  e.prev = nil
  e.next = gHead
  if gHead != nil: gHead.prev = e
  gHead = e
  if gTail == nil: gTail = e

proc touch(e: CacheEntry) =
  returnif(gHead == e)
  unlink(e)
  pushFront(e)

proc evictOne(e: CacheEntry) =
  unlink(e)
  gTable.del(e.id)
  gBytes -= e.bytes

proc evictCleanToFit(cost: int64) =
  ## Evict clean entries from the LRU end until this paste fits, or no clean entries remain.
  ## Dirty entries are skipped (pinned) — so we may walk past them toward the head.
  var e = gTail
  while e != nil and gBytes + cost > gMaxBytes:
    let prev = e.prev
    if not e.dirty: evictOne(e)
    e = prev

proc addPending(ownerIp: string, delta: int64) =
  let v = gPendingByIp.getOrDefault(ownerIp, 0) + delta
  if v <= 0: gPendingByIp.del(ownerIp)
  else: gPendingByIp[ownerIp] = v

proc clearEntries() =
  ## Unlink every node before dropping the list so the intrusive prev/next cycles break —
  ## atomicArc has no cycle collector, so a bulk drop of a populated list would otherwise leak it.
  var e = gHead
  while e != nil:
    let nxt = e.next
    e.prev = nil
    e.next = nil
    e = nxt
  gHead = nil
  gTail = nil

proc snapshotForPersist(id: string): CacheEntry =
  ## Return the entry ref for persistence (fields read off it are immutable until we markPersisted),
  ## or nil if it was deleted before we got to it. Dirty entries are un-evictable, so a present entry
  ## survives until we finish.
  withLock gLock:
    result = if gTable.hasKey(id): gTable[id] else: nil

proc persistLoop() {.thread.} =
  ## Drain the write queue: for each admitted paste, write its blob (large only) + DB row, then flip
  ## the entry clean. If the entry was deleted mid-flight, roll back the row/blob we just wrote.
  {.cast(gcsafe).}:
    while true:
      let id = gQueue.recv()
      let e = snapshotForPersist(id)
      if e == nil: continue                      # deleted before flush; nothing written yet
      var written = BlobId("")
      var stored = Paste(
        id: e.id, title: e.title, size: e.size, createdAt: e.createdAt,
        visibility: e.visibility, isTruncated: e.isTruncated,
        content: (if e.isTruncated: e.previewContent else: e.fullContent),
        blobId: BlobId(""))
      try:
        if e.isTruncated:
          let (bid, _) = saveFromString(e.fullContent)
          written = bid
          stored.blobId = bid
        insertPaste(stored, e.ownerIp)
      except CatchableError:
        # Persist failed: drop the cached copy (paste lost — accepted) and clean any orphan blob.
        if written.len > 0: discard deleteBlob(written)
        discard removeFromCache(id)
        continue
      if not markPersisted(id, written):
        # Entry deleted while we were writing -> roll back so we don't leave an orphan row/blob.
        discard deletePasteRow(id)
        if written.len > 0: discard deleteBlob(written)
