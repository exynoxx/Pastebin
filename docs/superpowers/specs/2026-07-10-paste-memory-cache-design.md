# In-memory-first paste writes with LRU read cache

**Date:** 2026-07-10
**Status:** Design approved, pending spec review
**Scope:** `pastebin-api/` (Nim backend) — paste create/read path only

## Goal

Speed up paste creation and absorb write bursts by storing a new paste in RAM and
returning its id immediately, while a background thread persists it to disk (blob)
and SQLite. Reads are served from memory until the paste is persisted; afterwards
the same in-memory copy lives on as a size-bounded LRU read cache. When memory is
full, fall back to today's synchronous "persist-before-respond" behavior.

Two objectives, weighted equally: **lower POST latency** and **better burst
tolerance** on the SD-card/btrfs-backed Raspberry Pi 3B.

## Accepted trade-off

A paste exists only in RAM between the POST response and the background flush
(steady-state: well under a second, since the persister is event-driven). If the
box crashes or reboots in that window, that paste is lost and the client holds an
id that now 404s. This is **acceptable** — the same durability posture as the
access log, which already buffers in memory. We do **not** add a durable
intent-log; that would put a disk write back into the hot path and undercut the
latency win.

## Non-goals

- File uploads (`uploadFile`, `uploadFolder`, `downloadFile`, …) — they already
  stream to/from disk via `saveFromFile`/`respondFile` and are out of scope.
- Graceful drain-on-shutdown. Matches existing patterns (ntfy/accesslog don't
  drain on exit). The steady-state loss window is tiny; not worth the complexity.
- Changing the wire format, the inline-vs-blob threshold, or the recent-pastes
  behavior beyond what's stated below.

## Architecture

A new service module `pastebin-api/src/pastecache.nim` sits in the onion beside
`db.nim` and `blobstore.nim`. Handlers call its free procs directly (no service
object on `Ctx`), same as every other service. It owns:

- One process-wide `Table[string, CacheEntry]` keyed by paste id.
- An intrusive doubly-linked LRU list over the entries.
- A single `Lock` (`gLock`) guarding the table, the LRU list, and all counters —
  the same shared-mutable-under-one-lock pattern as `ratelimit.nim` /
  `accesslog.nim`. Cross-thread global access uses `{.cast(gcsafe).}`.
- A `Channel[string]` (`gQueue`) of paste ids awaiting persistence.
- A single background persister `Thread`, mirroring the `ntfy.nim` worker
  (channel-drain) pattern — chosen over accesslog's periodic-flush because each
  write should drain ASAP, not on a timer.

### Cache entry & memory model

```nim
CacheEntry = ref object
  paste:   Paste     # content = FULL text always (even for pastes > inlineMax);
                     # blobId is "" until the flush assigns one
  ownerIp: string
  dirty:   bool      # true = not yet on disk/DB; dirty entries are UN-evictable
  bytes:   int64     # ≈ paste.content.len — the budget cost of this entry
  prev, next: CacheEntry   # LRU links (nil at ends)
```

Counters, all under `gLock`:

- `gBytes: int64` — total resident bytes (dirty + clean).
- `gDirtyBytes: int64` — bytes pinned by not-yet-persisted entries.
- `gPendingByIp: Table[string, int64]` — pending bytes per owner IP, for quota.

Key invariant: the cached `paste.content` is **always the full text**, regardless
of size. Preview/blob representations are derived — on the fly for display, and by
the persister when writing to disk. `paste.isTruncated`/`paste.blobId` on the
cached copy are not authoritative while dirty; display and persistence compute
what they need from `paste.size` and the full content.

### Configuration (`config.nim`)

- `cacheMaxBytes: int` — env `CACHE_MAX_BYTES`, default `134_217_728` (128 MB).
  Total budget across dirty pending writes **and** clean LRU entries combined.
- `pasteCacheEnabled: bool` — env `PASTE_CACHE`, default `true`. When false, the
  cache is bypassed entirely and every create takes the synchronous path (safety
  switch / A-B comparison).

Both compose files may set `CACHE_MAX_BYTES` explicitly later; the default is safe
under the API container's memory cap on the 906 MB Pi.

### Admission & eviction rule (under `gLock`)

To admit a new entry of `size` bytes:

1. Evict clean (non-dirty) LRU entries from the tail until
   `gBytes + size ≤ cacheMaxBytes`.
2. If it still won't fit — i.e. `gDirtyBytes + size > cacheMaxBytes`, or `size`
   alone exceeds the whole budget — **do not admit**; the caller takes the
   synchronous fallback path.

Only clean entries are evictable. Dirty entries pin memory until the persister
marks them clean. Reads and creates both move their entry to the MRU end.

## Create flow (`createPasteRecord` rewrite)

`createPasteRecord(cfg, title, content, visibilityIn, ownerIp): Paste` keeps its
signature (still called by both `handleCreatePaste` and create-paste-from-file):

1. Size check against `cfg.maxPasteBytes` → `PayloadTooLargeError` (unchanged).
2. `normalizeVisibility` (unchanged).
3. **Quota (now pending-aware):** enforce the per-IP cap against
   `sumUsageForOwner(ip) + pastecache.pendingBytesForOwner(ip)` so a burst of
   not-yet-persisted pastes can't slip past `maxStorageBytesPerIp`. Expose
   `pendingBytesForOwner(ip): int64` from `pastecache` (reads `gPendingByIp`
   under lock).
4. Build `Paste` with `id = newId()`, **full** content, `blobId = BlobId("")`,
   `createdAt = nowMillis()`.
5. If `cfg.pasteCacheEnabled`, attempt admission under `gLock`:
   - **Admitted:** insert dirty MRU entry; `gBytes += size`;
     `gDirtyBytes += size`; `gPendingByIp[ip] += size`; release lock;
     `gQueue.send(id)`; continue to step 6.
   - **Not admitted (or cache disabled):** synchronous path identical to today —
     `saveFromString` for large pastes, then `insertPaste`, with the existing
     blob-cleanup-on-insert-failure compensation. Optionally seed a **clean**
     cache entry afterward if it now fits (nice-to-have; skip if no room).
6. `notifyPasteCreated(p)` on the request thread (unchanged).
7. Return the `Paste` (create response is still `{"id": p.id}` only).

### Persister thread

Loop on `gQueue.recv()`:

1. Snapshot the entry under `gLock` (id, full content, size, ownerIp). If the id
   is gone (deleted before flush), skip.
2. Off-lock, do the disk work: if `size > cfg.inlinePasteMaxBytes`,
   `saveFromString(content)` → `blobId`; then `insertPaste` — inline row for small
   pastes (content = full text), or blob-backed row for large (content =
   `buildPreview(...)`, `blob_id` set, `is_truncated = 1`). `insertPaste`
   serializes on the existing `gWriteLock` internally.
3. Re-acquire `gLock`:
   - Entry **still present**: set `dirty = false`, record `blobId` on it,
     `gDirtyBytes -= size`, `gPendingByIp[ip] -= size`. The entry lives on as a
     clean LRU read-cache entry.
   - Entry **gone** (deleted mid-flight): roll back — `deletePasteRow(id)` +
     `deleteBlob(blobId)` if a blob was written. Prevents a delete-vs-flush orphan.
4. On persistent failure (retry a small fixed number of times): drop the entry
   from the cache (paste lost — accepted), decrement counters, delete any orphan
   blob, and log the error.

## Read flow

Both handlers consult the cache before SQLite via a `pastecache` lookup that
touches LRU on hit.

- **`handleGetPaste` (cache hit):** build the display `Paste` on the fly —
  `content = fullContent` if `size ≤ inlineMax`, else
  `buildPreview(fullContent, cfg.pastePreviewChars)`; `isTruncated = size >
  inlineMax`; respond `200` with `pasteJson`. Miss → `selectPaste(id)` as today.
- **`handleRawPaste` (cache hit):**
  - Entry **dirty** (not on disk yet): respond the full content from RAM,
    buffered, `text/plain` — **Range is ignored** (served as full `200`). Rare and
    minor: a Range request for a paste created within the last fraction of a second.
  - Entry **clean and blob-backed** (`blobId` set, on disk): fall through to
    `respondFile(blobPath(blobId), …, rangeHeader = …)` so Range keeps working.
  - Entry **clean and inline-sized:** respond full content from RAM.
  - Miss → today's disk/inline logic (`selectPaste`, `blobExists`, `respondFile`).

Lookups move the entry to MRU under `gLock`.

### Recent pastes

Unchanged — `selectRecentSummaries` reads SQLite only. A newly created public
paste appears in the recent list a few seconds late (once flushed). Accepted.

### Admin delete (`deletePaste`)

Under `gLock`, evict the entry from the table/LRU if present, capturing its
`blobId` and decrementing counters (and `gDirtyBytes`/`gPendingByIp` if it was
dirty). Then `deletePasteRow(id)` + `deleteBlob(blobId)` as today. The persister's
post-flush presence re-check (persister step 3, "entry gone") closes the
delete-during-flush race from the other direction.

## Wiring (`main.nim`)

Add `initPasteCache(cfg)` after `initBlobStore(cfg.blobStoragePath)` and before
`serve(...)`. It opens `gQueue`, initializes `gLock`/counters, and
`createThread`s the persister. No change to `ServerConfig`.

## Concurrency & GC-safety notes

- SQLite connections are thread-local (`db.nim` `tlConn`); the persister thread
  gets its own connection lazily via `conn()`. All writes still funnel through
  `gWriteLock`. No connection is shared across threads.
- Disk I/O (blob write, `insertPaste`) happens **off** `gLock` — the persister
  only holds `gLock` for the snapshot and the final state flip.
- Global access from the persister uses `{.cast(gcsafe).}`, matching `ntfy.nim`
  and `accesslog.nim`. The cached `Paste`/strings live on the ORC shared heap, as
  do `ratelimit.nim`'s tables.

## Testing

- **Unit / module (pastecache):** admission when under budget; eviction of clean
  entries to make room; refusal (sync fallback signal) when only dirty bytes
  remain or a single paste exceeds the budget; dirty→clean transition;
  `pendingBytesForOwner` accounting on admit and on flush; LRU ordering (touch on
  read, evict oldest clean first, never evict dirty).
- **E2e (run the binary, curl):**
  - Create small paste → `GET /api/pastes/{id}` and `/raw` return it immediately
    (before any flush could plausibly complete) → after a moment it's in SQLite.
  - Create paste > `inlinePasteMaxBytes` → `/raw` streams full content while
    dirty; after flush, blob exists on disk and Range requests work.
  - Fill the budget with dirty entries → next create takes the sync path and is
    still correct (row present before response).
  - Quota: burst of pending pastes from one IP is rejected once
    DB+pending exceeds `maxStorageBytesPerIp`.
  - Admin delete of a just-created (still-dirty) paste → gone from cache and never
    resurfaces after the flush (no orphan blob).
  - `PASTE_CACHE=false` → behavior identical to today (sync persist before
    response).
