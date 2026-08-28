## Read cache: a byte-bounded LRU of display Pastes, in front of SQLite.
##
## Pure cache — every entry is also (or is about to be) on disk, so anything here may be evicted at
## any moment. Durability of a fresh paste is writequeue's job, not this module's. `put` on create
## means the read right after a create is served from RAM instead of hitting the DB.
##
## Concurrency: one process-wide Lock guards everything; Lru itself is not thread-safe.

import std/[locks, tables, options]
import types
import common/templates

type
  CacheEntry = ref object
    paste: Paste
    bytes: int64                 ## budget cost = display content length
    prev, next: CacheEntry       ## LRU links; head = MRU, tail = LRU

  Lru = object
    table: Table[string, CacheEntry]
    head, tail: CacheEntry
    bytes, maxBytes: int64

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

proc remove(lru: var Lru, e: CacheEntry) =
  lru.unlink(e)
  lru.table.del(e.paste.id)
  lru.bytes -= e.bytes

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

initLock(gLock)

# ---- public API -------------------------------------------------------------

proc initPasteCache*(maxBytes: int64) =
  withLock gLock:
    gLru.reset(maxBytes)

proc put*(p: Paste) =
  ## Cache a display paste, evicting from the LRU end until it fits. A single paste over budget is
  ## simply not cached.
  let cost = p.content.len.int64
  withLock gLock:
    returnif: cost > gLru.maxBytes
    if gLru.table.hasKey(p.id): gLru.remove(gLru.table[p.id])
    while gLru.bytes + cost > gLru.maxBytes and gLru.tail != nil:
      gLru.remove(gLru.tail)
    let e = CacheEntry(paste: p, bytes: cost)
    gLru.table[p.id] = e
    gLru.pushFront(e)
    gLru.bytes += cost

proc get*(id: string): Option[Paste] =
  ## Lookup + move to MRU.
  withLock gLock:
    if not gLru.table.hasKey(id): return none(Paste)
    let e = gLru.table[id]
    if gLru.head != e:
      gLru.unlink(e)
      gLru.pushFront(e)
    result = some(e.paste)

proc remove*(id: string) =
  withLock gLock:
    if gLru.table.hasKey(id): gLru.remove(gLru.table[id])
