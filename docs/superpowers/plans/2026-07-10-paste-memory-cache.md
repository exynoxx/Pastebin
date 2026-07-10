# Paste Memory Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Return a new paste's id as soon as it is in RAM, persisting blob+SQLite on a background thread; serve reads from an in-memory LRU cache; fall back to synchronous persistence when memory is full.

**Architecture:** A new service module `pastebin-api/src/pastecache.nim` (module-global singleton, one `Lock`, `Channel`-fed persister thread — same shape as `accesslog.nim`/`ntfy.nim`) holds recently created/read pastes. `createPasteRecord` admits to the cache and returns immediately; the persister drains the channel and writes to `db.nim`/`blobstore.nim`. `getPaste`/`rawPaste`/admin-delete become cache-aware. Over-budget or cache-disabled creates take today's synchronous path.

**Tech Stack:** Nim 2.x, `std/[locks, tables, options]`, `std/unittest` (stdlib) for the cache-logic tests. SQLite via `db_connector`. No new third-party dependencies.

## Global Constraints

- Nim `>= 2.0.0`. **No new third-party dependencies** — stdlib only.
- Onion structure: dependencies point inward (controllers → services → stores). Handlers call service module procs directly; the only thing on `Ctx` is `cfg`.
- **Keep the feature in one file:** all cache + persister code lives in `pastebin-api/src/pastecache.nim` (mirrors `accesslog.nim`, which holds both its buffer and its flusher thread).
- Service concurrency pattern (mirror `accesslog.nim`/`ratelimit.nim`): process-wide state guarded by a single `Lock`; background-thread global access wrapped in `{.cast(gcsafe).}`.
- SQLite connections are thread-local (`db.nim conn()`); all writes serialize on `db.nim`'s `gWriteLock`. The persister thread just calls `insertPaste`/`deletePasteRow` normally and gets its own connection.
- Timestamps are Unix epoch-millis (`timeutil.nowMillis`). Public ids are base62 (`ids.newId`). Blob ids are 32-hex `BlobId` (distinct string).
- Config via env with `getLong`/`getEnv` fallbacks in `config.nim` (see existing entries).
- Type-check gate for every task: `cd pastebin-api && nim check --hints:off src/main.nim` (exit 0 = clean).

**Reusable e2e harness** (used by Tasks 3–6). Save as `/tmp/pb-e2e.sh` when a task needs it:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd /home/nicholas/Dokumenter/git/Pastebin/pastebin-api
nim c --hints:off -o:/tmp/pb-api src/main.nim
D=$(mktemp -d)
export SQLITE_PATH=$D/db.sqlite BLOB_STORAGE_PATH=$D/blobs PORT=18080 \
       ADMIN_TOKEN=testtok NETWORK_LOG=false "${EXTRA_ENV:-}"
# shellcheck disable=SC2086
env SQLITE_PATH=$D/db.sqlite BLOB_STORAGE_PATH=$D/blobs PORT=18080 \
    ADMIN_TOKEN=testtok NETWORK_LOG=false ${EXTRA_ENV:-} /tmp/pb-api &
SV=$!
trap 'kill $SV 2>/dev/null || true; rm -rf "$D"' EXIT
sleep 1
# --- per-task curls go here (the task body shows them) ---
```

---

## File Structure

- **Create** `pastebin-api/src/pastecache.nim` — the cache service: entry type, LRU list, admission/eviction, read/remove/markPersisted, pending-bytes accounting, persister thread + `initPasteCache`. (Tasks 2 & 3)
- **Create** `pastebin-api/tests/test_pastecache.nim` — `std/unittest` tests for the pure cache logic (admission, eviction, LRU order, accounting). (Task 2)
- **Modify** `pastebin-api/src/config.nim` — `cacheMaxBytes` + `pasteCacheEnabled`. (Task 1)
- **Modify** `pastebin-api/src/main.nim` — call `initPasteCache(cfg)`. (Task 3)
- **Modify** `pastebin-api/src/endpoints/pastes/createPaste.nim` — cache-first create + sync fallback. (Task 4)
- **Modify** `pastebin-api/src/quota.nim` — quota counts pending in-memory bytes. (Task 4)
- **Modify** `pastebin-api/src/endpoints/pastes/getPaste.nim` — cache-first read. (Task 5)
- **Modify** `pastebin-api/src/endpoints/pastes/rawPaste.nim` — cache-first raw read. (Task 5)
- **Modify** `pastebin-api/src/endpoints/admin/deletePaste.nim` — evict from cache on delete. (Task 6)

---

## Task 1: Config knobs

**Files:**
- Modify: `pastebin-api/src/config.nim`

**Interfaces:**
- Produces: `AppConfig.cacheMaxBytes: int64` (env `CACHE_MAX_BYTES`, default 134_217_728 = 128 MB), `AppConfig.pasteCacheEnabled: bool` (env `PASTE_CACHE`, default true).

- [ ] **Step 1: Add the fields to the `AppConfig` object**

In `config.nim`, in the `# --- storage / size limits ---` block (after `untitledTitleMaxChars*: int` on line 17), add:

```nim
        # --- paste memory cache ---
        cacheMaxBytes*: int64          # CACHE_MAX_BYTES  128 MB (dirty pending + clean LRU combined)
        pasteCacheEnabled*: bool       # PASTE_CACHE      true (false => always persist synchronously)
```

- [ ] **Step 2: Populate them in `loadConfig`**

In `loadConfig`, after the `result.accessLogFlushMs = ...` line (line 87), add:

```nim
    result.cacheMaxBytes           = getLong("CACHE_MAX_BYTES", 134_217_728)   # 128 MB
    result.pasteCacheEnabled       = getEnv("PASTE_CACHE", "true").toLowerAscii() != "false"
```

- [ ] **Step 3: Type-check**

Run: `cd /home/nicholas/Dokumenter/git/Pastebin/pastebin-api && nim check --hints:off src/main.nim`
Expected: exit 0, no errors.

- [ ] **Step 4: Commit**

```bash
cd /home/nicholas/Dokumenter/git/Pastebin
git add pastebin-api/src/config.nim
git commit -m "config: CACHE_MAX_BYTES + PASTE_CACHE for the paste memory cache"
```

---

## Task 2: `pastecache.nim` core (no persister thread yet) + unit tests

This task builds the pure, lock-guarded cache state machine and its tests. The persister thread and `initPasteCache` come in Task 3.

**Files:**
- Create: `pastebin-api/src/pastecache.nim`
- Create: `pastebin-api/tests/test_pastecache.nim`

**Interfaces:**
- Consumes: `types.Paste`, `types.BlobId`, `types.Visibility`.
- Produces:
  - `resetForTest*(maxBytes: int64)` — (re)initialize the singleton for tests: enabled, empty, given budget; idempotent about lock/channel init.
  - `cacheEnabled*(): bool`
  - `pendingBytesForOwner*(ownerIp: string): int64`
  - `tryAdmit*(display: Paste, fullContent, ownerIp: string): bool` — admit if it fits (evicting clean entries first); on success enqueue nothing yet (channel added in Task 3), return true. Budget cost = `fullContent.len`.
  - `getDisplayPaste*(id: string): Option[Paste]` — cache read; touches LRU; `content` = full text for inline, preview for large.
  - `acquireForRaw*(id: string): Option[CachedRawView]` and `content*(v: CachedRawView): lent string`
  - `removeFromCache*(id: string): tuple[wasCached: bool, blobId: BlobId]`
  - `markPersisted*(id: string, blobId: BlobId): bool` — flip dirty→clean, record blobId, release pending bytes; returns whether the entry was present.
  - `CachedRawView* = object` with exported `dirty*: bool`, `blobId*: BlobId` and a private `entry` ref.

- [ ] **Step 1: Write the module (pure cache; persister added in Task 3)**

Create `pastebin-api/src/pastecache.nim`:

```nim
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
import types

type
  CacheEntry = ref object
    id, title, ownerIp: string
    size, createdAt: int64
    visibility: Visibility
    isTruncated: bool            ## true => large paste; display uses previewContent
    previewContent: string       ## display text for large pastes; "" for inline (use fullContent)
    fullContent: string          ## full text (raw serving + persister)
    blobId: BlobId               ## "" until the persister writes the blob (large pastes)
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

# Private helpers declared before use (public API reads first).
proc unlink(e: CacheEntry)
proc pushFront(e: CacheEntry)
proc touch(e: CacheEntry)
proc evictOne(e: CacheEntry)
proc evictCleanToFit(cost: int64)
proc addPending(ownerIp: string, delta: int64)

# ---- public API ------------------------------------------------------------

proc cacheEnabled*(): bool = gEnabled

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
    gTable = initTable[string, CacheEntry]()
    gPendingByIp = initTable[string, int64]()
    gHead = nil
    gTail = nil

proc pendingBytesForOwner*(ownerIp: string): int64 =
  if not gEnabled: return 0
  withLock gLock:
    result = gPendingByIp.getOrDefault(ownerIp, 0)

proc tryAdmit*(display: Paste, fullContent, ownerIp: string): bool =
  ## Admit a new paste to the cache as a dirty entry. Returns false (caller persists synchronously)
  ## when the cache is disabled or the paste cannot fit even after evicting all clean entries.
  if not gEnabled: return false
  let cost = fullContent.len.int64
  withLock gLock:
    if cost > gMaxBytes: return false
    evictCleanToFit(cost)
    if gBytes + cost > gMaxBytes: return false   # only dirty bytes remain; cannot make room
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
    return true

proc getDisplayPaste*(id: string): Option[Paste] =
  ## Cache read for GET /api/pastes/{id}. Touches LRU. content = full (inline) or preview (large).
  if not gEnabled: return none(Paste)
  withLock gLock:
    if not gTable.hasKey(id): return none(Paste)
    let e = gTable[id]
    touch(e)
    result = some(Paste(
      id: e.id, title: e.title, size: e.size, createdAt: e.createdAt,
      visibility: e.visibility, isTruncated: e.isTruncated, blobId: e.blobId,
      content: (if e.isTruncated: e.previewContent else: e.fullContent)))

proc acquireForRaw*(id: string): Option[CachedRawView] =
  ## Cache read for GET /api/pastes/{id}/raw. Touches LRU; snapshots dirty/blobId under the lock and
  ## returns a handle whose content the caller reads WITHOUT the lock (content is immutable).
  if not gEnabled: return none(CachedRawView)
  withLock gLock:
    if not gTable.hasKey(id): return none(CachedRawView)
    let e = gTable[id]
    touch(e)
    result = some(CachedRawView(dirty: e.dirty, blobId: e.blobId, entry: e))

proc content*(v: CachedRawView): lent string = v.entry.fullContent

proc markPersisted*(id: string, blobId: BlobId): bool =
  ## Called by the persister after a successful blob+DB write: flip dirty->clean, record blobId,
  ## release the pending-bytes reservation. Returns false if the entry is gone (deleted mid-flight),
  ## in which case the caller must roll back the row/blob it just wrote.
  if not gEnabled: return false
  withLock gLock:
    if not gTable.hasKey(id): return false
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
  if not gEnabled: return (false, BlobId(""))
  withLock gLock:
    if not gTable.hasKey(id): return (false, BlobId(""))
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
  if gHead == e: return
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
```

- [ ] **Step 2: Write the failing tests**

Create `pastebin-api/tests/test_pastecache.nim`:

```nim
import std/[unittest, options, strutils]
import ../src/types
import ../src/pastecache

proc r(n: int): string = repeat('x', n)   # an n-byte string, for explicit budget math

# Build an inline display Paste + its full content (fullContent == content for inline).
proc inlinePaste(id, content: string): Paste =
  Paste(id: id, title: id, size: content.len.int64, isTruncated: false,
        createdAt: 0, visibility: Public, blobId: BlobId(""), content: content)

# Build a large display Paste (content = preview) paired with its full content.
proc largePaste(id, preview: string): Paste =
  Paste(id: id, title: id, size: 999999, isTruncated: true,
        createdAt: 0, visibility: Public, blobId: BlobId(""), content: preview)

suite "pastecache":
  test "admit under budget stores full content and accounts pending":
    resetForTest(1000)
    check tryAdmit(inlinePaste("a", "hello"), "hello", "ip1")
    let got = getDisplayPaste("a")
    check got.isSome
    check got.get.content == "hello"
    check pendingBytesForOwner("ip1") == 5

  test "single paste larger than budget is refused":
    resetForTest(4)
    check not tryAdmit(inlinePaste("a", "hello"), "hello", "ip1")
    check getDisplayPaste("a").isNone

  test "dirty entries are never evicted -> refusal when only dirty bytes remain":
    resetForTest(100)
    check tryAdmit(inlinePaste("a", r(30)), r(30), "ip1")
    check tryAdmit(inlinePaste("b", r(30)), r(30), "ip1")
    check tryAdmit(inlinePaste("c", r(30)), r(30), "ip1")
    # 90 dirty bytes used; a 30-byte paste needs eviction but nothing is clean.
    check not tryAdmit(inlinePaste("d", r(30)), r(30), "ip1")

  test "clean entries evicted in LRU order":
    resetForTest(100)
    check tryAdmit(inlinePaste("a", r(40)), r(40), "ip1")
    check markPersisted("a", BlobId(""))
    check tryAdmit(inlinePaste("b", r(40)), r(40), "ip1")
    check markPersisted("b", BlobId(""))
    # 80 clean bytes; admitting c(40) must evict the LRU clean entry (a).
    check tryAdmit(inlinePaste("c", r(40)), r(40), "ip1")
    check getDisplayPaste("a").isNone
    check getDisplayPaste("b").isSome
    check getDisplayPaste("c").isSome

  test "markPersisted flips dirty->clean and releases pending":
    resetForTest(100)
    check tryAdmit(inlinePaste("a", r(40)), r(40), "ip1")
    check pendingBytesForOwner("ip1") == 40
    check markPersisted("a", BlobId(""))
    check pendingBytesForOwner("ip1") == 0
    # Now clean: a fresh 80-byte paste can evict it.
    check tryAdmit(inlinePaste("b", r(80)), r(80), "ip1")
    check getDisplayPaste("a").isNone

  test "read touches LRU so least-recently-read is evicted":
    resetForTest(100)
    check tryAdmit(inlinePaste("a", r(40)), r(40), "ip1")
    check markPersisted("a", BlobId(""))
    check tryAdmit(inlinePaste("b", r(40)), r(40), "ip1")
    check markPersisted("b", BlobId(""))
    discard getDisplayPaste("a")     # touch a -> now MRU; b is LRU
    check tryAdmit(inlinePaste("c", r(40)), r(40), "ip1")
    check getDisplayPaste("b").isNone
    check getDisplayPaste("a").isSome

  test "removeFromCache clears a dirty entry and its pending bytes":
    resetForTest(100)
    check tryAdmit(inlinePaste("a", r(40)), r(40), "ip1")
    let rem = removeFromCache("a")
    check rem.wasCached
    check pendingBytesForOwner("ip1") == 0
    check getDisplayPaste("a").isNone

  test "large paste: display serves preview, raw serves full":
    resetForTest(1000)
    check tryAdmit(largePaste("a", "PREVIEW"), "FULLCONTENT", "ip1")
    check getDisplayPaste("a").get.content == "PREVIEW"
    let rv = acquireForRaw("a")
    check rv.isSome
    check rv.get.dirty
    check rv.get.content == "FULLCONTENT"

  test "unknown id misses":
    resetForTest(1000)
    check getDisplayPaste("nope").isNone
    check acquireForRaw("nope").isNone
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd /home/nicholas/Dokumenter/git/Pastebin/pastebin-api && nim c -r --hints:off tests/test_pastecache.nim`
Expected: compiles once `pastecache.nim` exists; if you run before writing the module it FAILS with "cannot open file: pastecache". After Step 1 exists, this run should PASS all suites. (If any assertion fails, fix `pastecache.nim` — the tests are the spec.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/nicholas/Dokumenter/git/Pastebin/pastebin-api && nim c -r --hints:off tests/test_pastecache.nim`
Expected: `[OK]` for all 9 tests, process exits 0.

- [ ] **Step 5: Type-check the whole app still builds**

Run: `cd /home/nicholas/Dokumenter/git/Pastebin/pastebin-api && nim check --hints:off src/main.nim`
Expected: exit 0 (pastecache.nim is not yet imported by the app, but it must compile).

- [ ] **Step 6: Commit**

```bash
cd /home/nicholas/Dokumenter/git/Pastebin
git add pastebin-api/src/pastecache.nim pastebin-api/tests/test_pastecache.nim
git commit -m "pastecache: LRU cache core + write-buffer state machine with unit tests"
```

---

## Task 3: Persister thread + `initPasteCache` wiring

Add the background thread that drains the write queue and the production initializer. Because this touches SQLite + the filesystem + a thread, it is verified by type-check + e2e (the repo's convention), not unit tests.

**Files:**
- Modify: `pastebin-api/src/pastecache.nim`
- Modify: `pastebin-api/src/main.nim`

**Interfaces:**
- Consumes: `config.AppConfig`, `db.insertPaste`, `db.deletePasteRow`, `blobstore.saveFromString`, `blobstore.deleteBlob`, and the Task-2 procs (`markPersisted`, private entry access).
- Produces: `initPasteCache*(cfg: AppConfig)` — configure the singleton, open the write channel, start the persister thread. No-op persister start when `cfg.pasteCacheEnabled` is false (cache disabled; `tryAdmit` always returns false).

- [ ] **Step 1: Add imports + queue/thread globals to `pastecache.nim`**

Change the import line at the top of `pastecache.nim` from `import std/[locks, tables, options]` / `import types` to:

```nim
import std/[locks, tables, options]
import types, config, db, blobstore
```

Add to the `var` block (after `gHead, gTail`):

```nim
  gQueue: Channel[string]              ## ids awaiting background persistence
  gPersister: Thread[void]
  gPersisterStarted: bool
```

- [ ] **Step 2: Enqueue on admit (production path)**

In `tryAdmit`, immediately after `addPending(ownerIp, cost)` and before `return true`, add:

```nim
    if gPersisterStarted: gQueue.send(e.id)
```

(Gated so the Task-2 unit tests — which never start the persister — keep working: they admit and call `markPersisted` manually.)

- [ ] **Step 3: Add the persister loop + `initPasteCache`**

Add these forward declarations to the private-helpers forward-decl block near the top:

```nim
proc persistLoop() {.thread.}
proc snapshotForPersist(id: string): CacheEntry
```

Add the public initializer to the public API section (after `cacheEnabled`):

```nim
proc initPasteCache*(cfg: AppConfig) =
  ## Production init: configure the singleton and start the background persister. When the cache is
  ## disabled, tryAdmit short-circuits to false and every create persists synchronously.
  if not gInited:
    initLock(gLock)
    gInited = true
  gEnabled = cfg.pasteCacheEnabled
  gMaxBytes = cfg.cacheMaxBytes
  gTable = initTable[string, CacheEntry]()
  gPendingByIp = initTable[string, int64]()
  if not gEnabled: return
  gQueue.open()
  gPersisterStarted = true
  createThread(gPersister, persistLoop)
```

Add the private helpers at the bottom (after `addPending`):

```nim
proc snapshotForPersist(id: string): CacheEntry =
  ## Return the entry ref for persistence (fields read off it are immutable until we markPersisted),
  ## or nil if it was deleted before we got to it. Dirty entries are un-evictable, so a present entry
  ## survives until we finish.
  withLock gLock:
    if gTable.hasKey(id): gTable[id] else: nil

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
```

- [ ] **Step 4: Wire `initPasteCache` in `main.nim`**

In `main.nim`, add `pastecache` to the app imports on line 6:

```nim
import config, db, blobstore, ratelimit, ntfy, clientip, accesslog, pastecache
```

And add the init call immediately after `initBlobStore(cfg.blobStoragePath)` (line 14) — the persister calls `insertPaste`/`saveFromString`, so DB + blob store must be initialized first:

```nim
    initPasteCache(cfg)
```

- [ ] **Step 5: Type-check**

Run: `cd /home/nicholas/Dokumenter/git/Pastebin/pastebin-api && nim check --hints:off src/main.nim`
Expected: exit 0.

- [ ] **Step 6: Rerun the cache unit tests (persister gating must not break them)**

Run: `cd /home/nicholas/Dokumenter/git/Pastebin/pastebin-api && nim c -r --hints:off tests/test_pastecache.nim`
Expected: all 9 tests `[OK]`. (They import `pastecache`, which now also imports `db`/`blobstore`; it must still compile and pass.)

- [ ] **Step 7: Commit**

```bash
cd /home/nicholas/Dokumenter/git/Pastebin
git add pastebin-api/src/pastecache.nim pastebin-api/src/main.nim
git commit -m "pastecache: background persister thread + initPasteCache wiring"
```

---

## Task 4: Cache-first create + pending-aware quota

Rewrite `createPasteRecord` to admit to the cache and return immediately, falling back to synchronous persistence. Make the quota count not-yet-persisted bytes.

**Files:**
- Modify: `pastebin-api/src/endpoints/pastes/createPaste.nim`
- Modify: `pastebin-api/src/quota.nim`

**Interfaces:**
- Consumes: `pastecache.tryAdmit`, `pastecache.pendingBytesForOwner`.
- Produces: unchanged public signatures — `createPasteRecord*(cfg, title, content, visibilityIn, ownerIp): Paste` and `handleCreatePaste*(ctx)`.

- [ ] **Step 1: Make the quota pending-aware**

In `quota.nim`, change the imports (line 7) and the usage line:

```nim
import db, apperrors, pastecache
```

In `ensureWithinQuota`, change the `usage` line (line 11) to add pending in-memory bytes:

```nim
    let usage = sumUsageForOwner(ownerIp) + pendingBytesForOwner(ownerIp)
```

(No import cycle: `pastecache` imports `db`/`blobstore`/`config`/`types`, none of which import `quota`.)

- [ ] **Step 2: Add the pastecache import to `createPaste.nim`**

In `createPaste.nim`, extend the import on lines 9–10 to include `pastecache`:

```nim
import ../../types, ../../db, ../../blobstore, ../../quota, ../../ntfy,
       ../../timeutil, ../../apperrors, ../../ratelimit, ../../ids, ../../pastecache
```

- [ ] **Step 3: Rewrite `createPasteRecord` (cache-first + sync fallback)**

Replace the body of `createPasteRecord` (lines 15–49) with:

```nim
proc createPasteRecord*(cfg: AppConfig, title, content, visibilityIn, ownerIp: string): Paste =
    ## Shared paste-creation pipeline. Raises PayloadTooLargeError (-> 413) on oversize/over-quota.
    ## Fast path: keep full content in RAM and return immediately; a background thread persists it.
    ## Fallback (cache disabled or over budget): persist the blob + DB row before returning.
    let id = newId()
    let ttl = if title.strip().len == 0: deriveTitle(content, cfg.untitledTitleMaxChars)
              else: title.strip()
    let byteCount = content.len.int64   # Nim strings are bytes => UTF-8 byte count
    let visibility = normalizeVisibility(visibilityIn)

    if byteCount > cfg.maxPasteBytes:
        raise newException(PayloadTooLargeError,
            &"Paste size exceeds the maximum allowed size of {cfg.maxPasteBytes div (1024*1024)}MB")

    ensureWithinQuota(ownerIp, byteCount, cfg.maxStorageBytesPerIp)

    # Build the display/stored shape. For large pastes the blob is written later (by the persister on
    # the fast path, or below on the fallback path), so blobId stays "" here.
    var p = Paste(id: id, title: ttl, size: byteCount, visibility: visibility, createdAt: nowMillis())
    if byteCount <= cfg.inlinePasteMaxBytes:
        p.content = content
        p.isTruncated = false
        p.blobId = BlobId("")
    else:
        p.content = buildPreview(content, cfg.pastePreviewChars)
        p.isTruncated = true
        p.blobId = BlobId("")

    # Fast path: admit full content to the cache and return now.
    if tryAdmit(p, content, ownerIp):
        notifyPasteCreated(p)
        return p

    # Fallback: persist synchronously before returning (blob first for large pastes, DB row last, with
    # blob-cleanup-on-insert-failure so a failed create can't orphan a blob on disk).
    if p.isTruncated:
        let (blobId, size) = saveFromString(content)
        p.blobId = blobId
        p.size = size
    try:
        insertPaste(p, ownerIp)
    except CatchableError:
        if p.blobId.len > 0: discard deleteBlob(p.blobId)
        raise
    notifyPasteCreated(p)
    p
```

(The forward decls on lines 12–13 and the `deriveTitle`/`buildPreview` bodies at the bottom stay as-is.)

- [ ] **Step 4: Type-check**

Run: `cd /home/nicholas/Dokumenter/git/Pastebin/pastebin-api && nim check --hints:off src/main.nim`
Expected: exit 0.

- [ ] **Step 5: e2e — create returns fast; content lands in DB; PASTE_CACHE=false parity**

Copy the harness from Global Constraints into `/tmp/pb-e2e.sh`, append the block below, then run twice: once with the cache on (default) and once with `EXTRA_ENV="PASTE_CACHE=false"`.

Append to the harness:

```bash
# Create a paste
ID=$(curl -s -XPOST localhost:18080/api/pastes -H 'Content-Type: application/json' \
      -d '{"title":"t","content":"hello world"}' | sed 's/.*"id":"\([^"]*\)".*/\1/')
echo "created id=$ID"
# Immediately readable (from cache or DB)
curl -sf localhost:18080/api/pastes/$ID | grep -q '"content":"hello world"' && echo "GET ok"
curl -sf localhost:18080/api/pastes/$ID/raw | grep -q '^hello world$' && echo "RAW ok"
# After the flush, it is in the recent list (DB-backed) and in SQLite
sleep 1
curl -sf localhost:18080/api/pastes | grep -q "\"id\":\"$ID\"" && echo "RECENT ok"
```

Run:
```bash
bash /tmp/pb-e2e.sh
EXTRA_ENV="PASTE_CACHE=false" bash /tmp/pb-e2e.sh
```
Expected (both runs): prints `created id=…`, `GET ok`, `RAW ok`, `RECENT ok`; no curl errors.

- [ ] **Step 6: Commit**

```bash
cd /home/nicholas/Dokumenter/git/Pastebin
git add pastebin-api/src/endpoints/pastes/createPaste.nim pastebin-api/src/quota.nim
git commit -m "pastes: cache-first create with sync fallback; pending-aware quota"
```

---

## Task 5: Cache-first reads (getPaste + rawPaste)

**Files:**
- Modify: `pastebin-api/src/endpoints/pastes/getPaste.nim`
- Modify: `pastebin-api/src/endpoints/pastes/rawPaste.nim`

**Interfaces:**
- Consumes: `pastecache.getDisplayPaste`, `pastecache.acquireForRaw`, `pastecache.content`.

- [ ] **Step 1: getPaste — check cache first**

Replace `getPaste.nim` in full:

```nim
## GET /api/pastes/{id} — one paste's metadata + (inline) content.

import std/[json, options]
import ../routes
import ../../types, ../../db, ../../json, ../../pastecache

serialize(Paste, omit = [blobId])

proc handleGetPaste*(ctx: Ctx, id: string) =
    let cached = getDisplayPaste(id)
    if cached.isSome:
        ctx.req.respond(200, pasteJson(cached.get))
        return
    let p = fetchOr404(ctx, selectPaste(id), "Paste not found")
    ctx.req.respond(200, pasteJson(p))
```

- [ ] **Step 2: rawPaste — check cache first**

Replace `rawPaste.nim` in full:

```nim
## GET /api/pastes/{id}/raw — full raw content: from the memory cache, a streamed blob (Range-capable),
## or inline text. A cache hit serves the full content from RAM while the paste is still pending; once
## it is persisted and blob-backed we stream from disk so Range keeps working.

import std/options
import ../routes
import ../../types, ../../db, ../../blobstore, ../../pastecache

proc handleRawPaste*(ctx: Ctx, id: string) =
    let rv = acquireForRaw(id)
    if rv.isSome:
        let v = rv.get
        if (not v.dirty) and v.blobId.len > 0 and blobExists(v.blobId):
            ctx.req.respondFile(blobPath(v.blobId), "text/plain; charset=utf-8",
                rangeHeader = ctx.req.header("Range"))
        else:
            ctx.req.respond(200, v.content, contentType = "text/plain; charset=utf-8")
        return
    let p = fetchOr404(ctx, selectPaste(id), "Paste not found")
    if p.blobId.len > 0 and blobExists(p.blobId):
        ctx.req.respondFile(blobPath(p.blobId), "text/plain; charset=utf-8",
            rangeHeader = ctx.req.header("Range"))
    else:
        ctx.req.respond(200, p.content, contentType = "text/plain; charset=utf-8")
```

- [ ] **Step 3: Type-check**

Run: `cd /home/nicholas/Dokumenter/git/Pastebin/pastebin-api && nim check --hints:off src/main.nim`
Expected: exit 0.

- [ ] **Step 4: e2e — small + large paste, before and after flush**

Copy the harness to `/tmp/pb-e2e5.sh` and append:

```bash
# Large paste (> 256 KB) forces the blob path once flushed.
python3 -c "print('X'*300000)" > /tmp/big.txt
BODY=$(python3 -c "import json,sys;print(json.dumps({'title':'big','content':open('/tmp/big.txt').read()}))")
ID=$(curl -s -XPOST localhost:18080/api/pastes -H 'Content-Type: application/json' -d "$BODY" \
      | sed 's/.*"id":"\([^"]*\)".*/\1/')
echo "big id=$ID"
# getPaste returns a preview (isTruncated true) for a large paste, from cache
curl -sf localhost:18080/api/pastes/$ID | grep -q '"isTruncated":true' && echo "GET big preview ok"
# raw returns the full 300001 bytes (300000 X + newline)
test "$(curl -sf localhost:18080/api/pastes/$ID/raw | wc -c)" = "300001" && echo "RAW big len ok"
sleep 1
# after flush: still full via raw, and a Range request now works (served from disk)
test "$(curl -sf localhost:18080/api/pastes/$ID/raw | wc -c)" = "300001" && echo "RAW big len (post-flush) ok"
curl -sf -H 'Range: bytes=0-9' localhost:18080/api/pastes/$ID/raw | wc -c | grep -q '^10$' && echo "RANGE ok"
```

Run: `bash /tmp/pb-e2e5.sh`
Expected: `big id=…`, `GET big preview ok`, `RAW big len ok`, `RAW big len (post-flush) ok`, `RANGE ok`.

- [ ] **Step 5: Commit**

```bash
cd /home/nicholas/Dokumenter/git/Pastebin
git add pastebin-api/src/endpoints/pastes/getPaste.nim pastebin-api/src/endpoints/pastes/rawPaste.nim
git commit -m "pastes: serve getPaste/rawPaste from the memory cache when present"
```

---

## Task 6: Cache-aware admin delete

**Files:**
- Modify: `pastebin-api/src/endpoints/admin/deletePaste.nim`

**Interfaces:**
- Consumes: `pastecache.removeFromCache`.

- [ ] **Step 1: Evict from cache on delete**

Replace `deletePaste.nim` in full:

```nim
## DELETE /api/admin/pastes/{id} — admin delete a paste and its backing blob (if any).
## Evicts the in-memory copy too: a paste may exist only in the cache (not yet persisted), or in both
## the cache and SQLite. removeFromCache reports the on-disk blob (if the paste was already flushed) so
## we can delete it; the persister's post-write presence check cleans up any in-flight write.

import std/[json, options]
import ../routes, guard
import ../../types, ../../db, ../../blobstore, ../../pastecache

proc handleAdminDeletePaste*(ctx: Ctx, id: string) =
    if not ctx.requireAdmin(): return
    let cached = removeFromCache(id)
    if cached.wasCached:
        if cached.blobId.len > 0: discard deleteBlob(cached.blobId)
        discard deletePasteRow(id)   # no-op if it was never persisted
        ctx.req.respond(200, $(%*{"message": "Paste deleted successfully"}))
        return
    let p = fetchOr404(ctx, selectPaste(id), "Paste not found")
    if p.blobId.len > 0:
        discard deleteBlob(p.blobId)
    if deletePasteRow(id):
        ctx.req.respond(200, $(%*{"message": "Paste deleted successfully"}))
    else:
        ctx.respondError(404, "Paste not found")
```

- [ ] **Step 2: Type-check**

Run: `cd /home/nicholas/Dokumenter/git/Pastebin/pastebin-api && nim check --hints:off src/main.nim`
Expected: exit 0.

- [ ] **Step 3: e2e — delete a paste, verify it is gone and leaves no blob**

Copy the harness to `/tmp/pb-e2e6.sh` and append:

```bash
# Large paste so a blob exists after flush.
BODY=$(python3 -c "import json;print(json.dumps({'title':'d','content':'Y'*300000}))")
ID=$(curl -s -XPOST localhost:18080/api/pastes -H 'Content-Type: application/json' -d "$BODY" \
      | sed 's/.*"id":"\([^"]*\)".*/\1/')
sleep 1   # let it flush to disk
BEFORE=$(find "$D/blobs" -type f | wc -l)
curl -sf -XDELETE localhost:18080/api/admin/pastes/$ID -H 'X-Admin-Token: testtok' \
      | grep -q 'deleted successfully' && echo "DELETE ok"
# gone from the API
test "$(curl -s -o /dev/null -w '%{http_code}' localhost:18080/api/pastes/$ID)" = "404" && echo "GET 404 ok"
# blob removed (one fewer file than before the delete)
AFTER=$(find "$D/blobs" -type f | wc -l)
test "$AFTER" -lt "$BEFORE" && echo "BLOB removed ok"
```

Run: `bash /tmp/pb-e2e6.sh`
Expected: `DELETE ok`, `GET 404 ok`, `BLOB removed ok`.

- [ ] **Step 4: Full type-check + unit tests one more time**

Run:
```bash
cd /home/nicholas/Dokumenter/git/Pastebin/pastebin-api
nim check --hints:off src/main.nim
nim c -r --hints:off tests/test_pastecache.nim
```
Expected: type-check exit 0; all cache unit tests `[OK]`.

- [ ] **Step 5: Commit**

```bash
cd /home/nicholas/Dokumenter/git/Pastebin
git add pastebin-api/src/endpoints/admin/deletePaste.nim
git commit -m "admin: evict paste from memory cache on delete"
```

---

## Post-implementation: documentation

After all tasks pass, update `pastebin-api`-facing docs so the cache is discoverable:

- [ ] Add a short "Paste memory cache" bullet to the backend services list in `CLAUDE.md` (near `blobstore.nim`/`quota.nim`): what `pastecache.nim` does, the `CACHE_MAX_BYTES`/`PASTE_CACHE` knobs, and the accepted crash-loss window.
- [ ] Note the two new env vars in `docs/PERFORMANCE.md` if that file enumerates tunables.
- [ ] Commit: `docs: document the paste memory cache + CACHE_MAX_BYTES/PASTE_CACHE`.

---

## Notes for the implementer

- **Why no unit tests outside Task 2:** the repo has no unit-test harness; its convention (CLAUDE.md) is `nim check` + e2e curl. The cache state machine is pure and bug-prone, so it earns real `std/unittest` coverage; the persister/handlers need SQLite + filesystem + a live thread, so they are exercised end-to-end instead.
- **The dirty→clean window is not directly observable in e2e** (the persister is event-driven and drains in well under the `sleep 1`). Correctness of that transition, eviction, and the budget/fallback boundary is covered by the Task 2 unit tests; e2e proves the combined path is correct.
- **Sync-fallback does not seed the cache.** When `tryAdmit` refuses (over budget), the paste is persisted synchronously and NOT inserted into the cache. This keeps the fallback simple; it is the rare over-budget case, and the entry will populate the cache naturally on its next read only if you later add read-through seeding (out of scope).
