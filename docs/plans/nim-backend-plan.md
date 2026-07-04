# Alternate Nim backend for Pastebin

## Context

The production backend is .NET 8 (`pastebin-api/`) running on a Raspberry Pi 3B behind
Tailscale Funnel, memory-capped at 250 MB. This task builds a **drop-in replacement backend in
Nim** — same SQLite schema, same blob layout, same env vars, same port `8080`, and byte-identical
HTTP/JSON contract — so it can read the *existing* production DB and swap in behind nginx with no
migration. Motivation: a leaner native binary (Nim idles at a few MB RSS vs .NET's runtime + GC
heap) that is a better fit for the Pi's constraints.

Scope: **fully replace** the .NET backend. Build the Nim app + its Dockerfile, **and repoint every
build/deploy pipeline (Taskfile, all compose files, nginx if needed) at it**, then cut the Pi over to
the Nim image. The Nim container is plug-compatible: listens on `:8080`, persists to
`/data/db/pastebin.db` and `/data/blobs`, honors the same env vars, runs as uid/gid `1654`, non-root,
under the 250 MB cap — so it swaps in behind nginx and reads the live production DB with no migration.
The .NET source stays in-tree for rollback until the Nim backend is verified in production, then is
deleted in a follow-up.

Decisions locked with the user: **full drop-in parity · Mummy HTTP server · stream uploads to disk
manually · full replacement of the .NET backend incl. pipelines and the Pi.**

## Key architectural constraint (read first)

Upstream **Mummy cannot faithfully stream** this app's binary traffic under the memory cap:
- `newServer(... maxBodyLen = 1024*1024 ...)` — the request `body` is a **fully-buffered `string`**;
  raising `maxBodyLen` to 1 GB would buffer the whole upload in RAM (verified from the Mummy API docs).
- `respond(request, statusCode, headers, body: sink string)` is the **only** response path — no
  streaming responses, **no HTTP Range / 206** support. A 1 GB download would allocate 1 GB.

The .NET backend streams both directions and supports Range on 3 endpoints
(`/api/pastes/{id}/raw`, `/api/files/{id}/download`, `/api/files/{id}/raw` — all
`enableRangeProcessing:true`). To honor "Mummy + stream to disk manually" we **vendor Mummy** (MIT,
`vendor/mummy/`) and add two focused patches:

1. **Request-body spill-to-disk.** In Mummy's main read loop, when `Content-Length` exceeds a
   threshold (e.g. `INLINE_PASTE_MAX_BYTES`, 256 KB) write the incoming body to a temp file instead
   of growing a `string`, and expose `request.bodyFilePath` to the handler. Handlers then parse the
   multipart from that on-disk file in bounded-size chunks — memory stays at the copy-buffer size.
2. **File/Range response.** Add `respondFile(request, path, contentType, rangeHeader,
   contentDisposition)` that emits `200`/`206` with `Accept-Ranges: bytes`, `Content-Range`, and
   streams the file from disk in chunks (sendfile if practical) instead of loading it into a `string`.

(Alternative considered and rejected for this pass: depend on the **MummyX** fork, which advertises
"large file uploads" — but its streaming API is undocumented and it's a single-maintainer fork;
vendoring a small patch to upstream keeps the surface reviewable and self-contained. If patch #1/#2
prove too invasive, fall back to MummyX with a one-line dependency swap.)

## Reference: exact behavior to replicate

The .NET source is the source of truth. Mirror these precisely (all confirmed during exploration):

- **SQLite schema** (`pastebin-api/services/SqliteConnectionFactory.cs:60-99`): tables `pastes`
  (`id, title, content, size, is_truncated, created_at, blob_id, visibility, owner_ip`) and `files`
  (`id, original_name, content_type, size, uploaded_at, blob_id, owner_ip`); indexes on
  `created_at DESC`, `owner_ip`. Startup PRAGMAs: `journal_mode=WAL`, `synchronous=NORMAL`,
  `busy_timeout=5000`. Use `IF NOT EXISTS` + the idempotent column-add migrations so it opens the
  live DB cleanly.
- **Paste logic** (`pastebin-api/services/PasteService.cs`): 8-char id from `[A-Za-z0-9]`;
  `size` = UTF-8 byte count; `visibility` is `"private"` else `"public"`; `>MAX_PASTE_BYTES`(10MB)→413;
  inline if `<=INLINE_PASTE_MAX_BYTES`(256KB) else blob + preview (`PASTE_PREVIEW_CHARS`=8192 chars +
  `"\n\n… (truncated …)"`), `is_truncated=1`; blank title → first non-empty line capped at 40 chars.
  Timestamps ISO-8601 round-trip UTC with trailing `Z`. **No expiry, no paste-delete.**
- **Recent list** (`PasteService.cs:119-151`): `UNION ALL` of **public** pastes (`kind='paste'`,
  `contentType=null`) and **all** files (`kind='file'`, title=original_name, createdAt=uploaded_at),
  newest first, `LIMIT` (default 10).
- **Blob store** (`pastebin-api/services/BlobStore.cs`): blobId = 32-char lowercase hex (GUID "N");
  2-char shard dir (`blobId[0..1]`, fallback `"00"`); path `<root>/<shard>/<blobId>`; atomic write
  to `<final>.tmp` then rename; seekable reads for Range.
- **File upload** (`pastebin-api/services/FileUploadService.cs`): file id = first 12 hex of a GUID;
  single-file streams to blob; folder→zip stages a temp `.zip` (per-entry `Optimal`), zip-entry names
  sanitized against path traversal (`\`→`/`, drop `.`/`..`/empty), `originalName=<folderName>.zip`
  (default `folder.zip`), `contentType=application/zip`; quota reserved on the **uncompressed** sum.
- **Quota** (`pastebin-api/services/StorageQuota.cs`): `SUM(size)` over both tables for `owner_ip`;
  `usage+new > MAX_STORAGE_BYTES_PER_IP`(100MB) → 413 with the exact message string. Non-transactional.
- **Client IP** (`pastebin-api/services/ClientIp.cs:13-31`): `X-Real-IP` → first `X-Forwarded-For`
  (trimmed) → connection remote → `"unknown"`.
- **Rate limiting** (`pastebin-api/program.cs:90-132`): per-IP sliding window 120/min, global sliding
  600/min, global concurrency 50, all → **503** + `Retry-After: 10` +
  `{"error":"Server busy or rate limit exceeded. Please retry shortly."}`; `uploads` fixed window
  10/min on the two upload routes. Paste-creation guard (`services/PasteRateGuard.cs`): >10 pastes/60s
  trips a 30-min penalty box (1/min), → **429** + `Retry-After` + `{error, retryAfterSeconds, penalized}`.
- **ntfy** (`pastebin-api/services/NtfyNotifier.cs`): fire-and-forget, no-op when `NTFY_TOPIC` empty;
  POST JSON `{topic,title,message,click,tags:["memo"],priority:3}` to `NTFY_SERVER_URL`, 5s timeout,
  swallow errors. Titles/messages/`FormatSize` per the .NET file.
- **JSON casing**: responses **camelCase**; `blob_id`/`owner_ip` never emitted; create-paste returns
  `{id}`; create-paste-from-file returns `{pasteId, id}` (both, same value).
- **Full endpoint/DTO contract**: the 12 routes and exact field names/status codes as inventoried
  from `pastebin-api/controllers/` — reproduce verbatim (see the controller files).

## Proposed structure (`pastebin-api-nim/`)

```
pastebin-api-nim/
  pastebin.nimble            # deps: db_connector, zippy (zip); mummy is vendored
  src/
    main.nim                 # newServer, router, middleware chain (CORS → rate limit → route)
    config.nim               # env → typed AppConfig (mirrors AppLimits.cs + program.cs defaults)
    db.nim                   # thread-local DbConn, schema init + PRAGMAs (SqliteConnectionFactory.cs)
    clientip.nim             # ClientIp.cs precedence
    blobstore.nim            # sharded atomic write, ranged reads (BlobStore.cs)
    pastes.nim               # PasteService.cs: create/get/raw/list, id-gen, preview, title
    files.nim                # FileUploadService.cs: upload/folder-zip/from-file/get/download/raw/delete
    quota.nim                # StorageQuota.cs
    ratelimit.nim            # 3-tier limiter + uploads policy (thread-safe counters/locks)
    pasteguard.nim           # PasteRateGuard.cs state machine
    ntfy.nim                 # NtfyNotifier.cs (async fire-and-forget)
    multipart.nim            # chunked multipart/form-data parser over an on-disk body file
    routes/                  # thin handlers per controller (pastes, files, debug)
    json.nim                 # camelCase response builders / error helper {"error": ...}
  vendor/mummy/              # vendored + patched (bodyFilePath spill, respondFile/Range)
  Dockerfile
```

## Dependencies

- **HTTP**: vendored **Mummy** (patched as above) — multithreaded, low idle memory.
- **SQLite**: `db_connector/db_sqlite` (maintained successor to std `db_sqlite`; runs the PRAGMAs).
  Open **one `DbConn` per worker thread** (thread-local, lazy) — WAL gives concurrent readers + a
  single writer; a process-wide write mutex guards inserts/deletes to avoid `SQLITE_BUSY` churn.
- **Zip**: `zippy` for the folder→zip path (streams entries; `Optimal`-equivalent level).
- Build flags: `--mm:orc -d:release -d:useMalloc` for predictable, low RSS. Tune `workerThreads`
  well below Mummy's `cores*10` default (e.g. 8) to stay under 250 MB on the 4-core Pi.

## Dockerfile

Multi-stage, arm64 target, mirroring the repo's "native build, tiny runtime" ethos:
- **Build stage**: `nim` toolchain image; `nimble install -d`; `nim c -d:release --mm:orc
  -d:useMalloc --cpu:arm64 --os:linux -o:/out/pastebin` (cross-compile Nim→C→arm64 via an arm64 gcc/
  `zig cc` to avoid QEMU, matching the `--platform=$BUILDPLATFORM` intent in `pastebin-api/Dockerfile`;
  QEMU-native build is the simpler fallback).
- **Runtime stage**: `alpine`; copy the static binary + sqlite/pthread libs; `mkdir -p /data/blobs
  /data/db && chown 1654:1654`; `USER 1654`; `EXPOSE 8080`; entrypoint the binary. Bind to `0.0.0.0:8080`
  (read `ASPNETCORE_URLS` port if set, default 8080).

## Pipeline & deployment changes (replace .NET)

The Nim image ships under the **same image name/tag** the infra already references
(`${REGISTRY}/pastebin-api:rpi`) and the **same compose service name** (`pastebin-api`) on port 8080,
so most wiring is a build-source repoint rather than a rewrite:

- **`Taskfile.yml`** (`build`/deploy targets, ~`:91-96`): point `docker buildx build` at
  `pastebin-api-nim/Dockerfile` instead of `pastebin-api/Dockerfile`; keep `--platform linux/arm64`,
  `--push`, `--provenance=false --sbom=false`, the `127.0.0.1:5000` registry, and the SSH
  `compose pull && up -d` deploy step unchanged. The host-dir chown to `1654:1654` (`:110-111`) still
  applies.
- **`docker-compose.yaml`** (`:7-27`) and **`docker-compose.dev.yaml`** (`:4-17`): repoint `build:`
  to the Nim Dockerfile. Keep `expose: 8080`, the named volumes, and the size/rate-limit env vars.
  Drop the .NET-only `ASPNETCORE_*` vars (the Nim app binds `0.0.0.0:8080` itself; keep reading the
  `ASPNETCORE_URLS` port only as a harmless compat shim). Same for the `Development` env value.
- **`docker-compose.rpi.yaml`** (`:25-60`): image ref (`pastebin-api:rpi`), bind-mounts, `user: 1654`,
  `mem_limit: 250m`, `restart: unless-stopped`, logging, and the `NTFY_*`/`PUBLIC_BASE_URL`/size/
  rate-limit env stay as-is. **Remove `DOTNET_GCHeapHardLimit`** (.NET-only). No nginx change needed:
  `upstream backend { server pastebin-api:8080; }` (`nginx/nginx.conf:6-8`) already matches.
- **nginx**: unchanged — same service name and port. (The `nginx/Dockerfile` build of the SPA is
  untouched.)
- **`pastebin-api/` (.NET)**: left in the repo for rollback; removed from all build/deploy paths now,
  deleted in a follow-up once the Nim backend is confirmed healthy in production.

## Verification (end-to-end)

1. `docker build` the Nim image; run it against a **copy** of the existing `pastebin.db` + `blobs/`
   (bind-mount) to prove schema/blob compatibility — it must open and list existing rows unchanged.
2. Point the built React SPA (or `curl`) at the Nim container and exercise every route, diffing
   responses against the .NET backend on the same inputs:
   - `POST /api/pastes` (public/private, blank-title derivation, >10MB→413), `GET /api/pastes/{id}`,
     `GET /api/pastes/{id}/raw` (+ `Range:` header → **206** + `Content-Range`), `GET /api/pastes?limit=`.
   - `POST /api/files/upload` (multipart `file`), `POST /api/files/upload-folder` (repeated `files` +
     `folderName` → downloadable zip), `POST /api/files/create-paste-from-file` (`{pasteId,id}`),
     `GET /api/files/{id}`, `/download` (Content-Disposition + Range), `/raw` (inline + nosniff),
     `DELETE /api/files/{id}`.
   - `GET /api/debug/ip` header echo; error shape `{"error":...}`; camelCase field names.
3. **Streaming/memory proof** (the whole point): upload a ~1 GB file and download it with the
   container held at `mem_limit: 250m`; watch `docker stats` stay well under the cap and confirm the
   blob lands correctly. Verify a `Range` request returns 206 with the right bytes.
4. **Rate limits**: burst >10 pastes/60s → 429 + `retryAfterSeconds`/`penalized`; >120 req/min/IP →
   503 + `Retry-After: 10`; >10 uploads/min → the uploads-policy rejection.
5. Set `NTFY_TOPIC` and confirm a create fires one ntfy POST and that ntfy failure never fails the request.
6. **Local full-stack**: `docker compose up` (default + dev files) with the Nim build source and the
   real SPA in front — click through create/view/list/upload/download/delete in the browser.
7. **Production cutover on the Pi**: `task` (build arm64 → push to the on-Pi registry → SSH
   `compose pull && up -d`). Confirm `task ps` shows the recreated `pastebin-api` container healthy,
   `task logs` is clean, `https://<host>.<tailnet>.ts.net/` serves and lists the **existing** pastes/files
   (proving live-DB compatibility), and `docker stats` on the Pi shows RSS far under 250 MB.

## Risks / notes

- **Mummy patches (#1/#2) are the highest-effort, highest-risk part** — they touch the vendored
  event loop. MummyX is the ready fallback if the patch proves too invasive.
- Quota is intentionally non-transactional in .NET (TOCTOU) — replicate as-is, don't "fix."
- `visibility` is only `public`/`private` (no "unlisted"); `includeContent` on create-paste-from-file
  is accepted but unused — keep both behaviors identical.
- SQLite thread-safety across Mummy workers is the main correctness pitfall — enforce thread-local
  connections + a write mutex from the start.
- **Cutover safety**: because the Nim image reuses tag `pastebin-api:rpi`, rollback = re-push the .NET
  image to that tag and `compose up -d`. Keep the `pastebin-api/` source until the Nim backend has a
  clean production soak. Back up `db/pastebin.db` (+ WAL) on the Pi before the first cutover; the Nim
  app opening WAL with the same PRAGMAs makes it compatible, but a snapshot is cheap insurance.
