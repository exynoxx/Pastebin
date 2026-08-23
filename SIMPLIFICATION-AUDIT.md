# Simplification audit — Pastebin

Whole-repo hunt for over-engineering: what to delete, what the stdlib or the platform already
ships, and what flexibility nobody uses. Scope is complexity only — correctness bugs, security
holes and performance are explicitly out of scope and routed to a normal review pass.

Baseline: ~5,800 lines of real source (excluding `node_modules/` and build output).

**Status legend** — ✅ implemented in this pass · ⬜ not yet applied

---

## Overlapping limits: nginx and the code enforce the same things twice

The single most under-documented source of redundancy in this repo. nginx and the API each
independently enforce **the same three limits**, and in the deployed topology nginx always wins two
of them. The code-side copies are backstops for a request that bypasses the proxy — which nothing
does, because Funnel → nginx → API is the only path in.

| Limit | nginx | API | Who actually fires |
|---|---|---|---|
| **Concurrency** | `limit_conn api_all 30`, `api_write 3` | `RATE_LIMIT_GLOBAL_CONCURRENCY` 30 | **nginx.** The app's cap sat *above* its own worker count, so its 503 branch was unreachable — see below. |
| **Body size** | `client_max_body_size 51M` | `MAX_REQUEST_BYTES` ~51 MB | **nginx**, on `Content-Length`, before a byte of body is read. The API's check never sees an oversize request in production. |
| **Idle timeout** | `proxy_read/send_timeout 600s`, `client_body_timeout 600s` | `REQUEST_TIMEOUT_MS` 30 s | **the API** — inverted. Its 30 s is 20× tighter, so nginx's three 600 s values can never expire first. |

Three consequences worth internalising:

1. **The app-level rate limiter was dead code.** `listenAndServe` runs exactly `numThreads` blocking
   accept loops (`webframework/httpserver.nim:426-431`), so max in-flight requests == `WORKER_THREADS`
   — 6 in production, 8 locally. The cap was 30. `gConcurrent < 30` was *always* true; the 503 branch
   had never once executed. `ratelimit.nim`'s own header conceded it: *"the true ceiling is
   WORKER_THREADS."* It took a process-wide lock on every single request to guard a counter that
   could not trip.
2. **A shed burst never reaches the API.** nginx answers it with a 503 directly, so it lands in
   nginx's log and **not** in `access.log` — despite `accesslog.nim` being registered as the
   outermost middleware specifically to catch 503s. It only catches the app's own.
3. **`REQUEST_TIMEOUT_MS` is inert as configured.** It's documented in `.env.example` and the README,
   but neither compose file forwards it to the container, so setting it in `.env` does nothing; only
   the baked-in 30 s default applies.

Also in this family: `MAX_REQUEST_BYTES` is declared in **six** places (`config.nim:52`, both compose
files, `.env.example`, `.env`, nginx's `51M`, and the README table). Changing the limit means editing
six files and hoping.

---

## Tier 1 — provably dead (delete, zero behaviour change)

✅ `delete:` **`pastebin-api/src/main` — a 1.39 MB x86-64 ELF binary committed to git.** `git rm
--cached` + gitignore it (the sibling rule for `/pastebin-api/pastebin` already existed). **56% of the
repo's tracked bytes.** It also rode into every API image via `COPY pastebin-api/src ./src`, busting
that layer's cache. `[pastebin-api/src/main]`

✅ `delete:` **`ratelimit.nim` in full — the 503 branch is unreachable.** See the overlap section
above. Deleted the file, the `globalConcurrency` config field, the middleware registration, the
`initRateLimiter` call and 3 compose/env rows. **~62 lines** `[pastebin-api/src/ratelimit.nim]`

✅ `delete:` **`docs/superpowers/` + `docs/access-log-admin-plan.md` — plans for features already
shipped.** All four specs describe merged work (webframework extraction → `webframework/` exists;
admin list-files → `listPastes.nim`; paste memory cache → `pastecache.nim`); the 922-line cache plan
is a checkbox list whose feature landed in `3ca612b`. Git history is the record. **~1,600 lines**
`[docs/]`

✅ `delete:` **`loadtest/` — a one-off that already served its purpose.** Single commit (`487b644`),
zero references from any doc, Taskfile or CI. `wait_for_deploy.sh` was provably dead: it polled a
**hardcoded image id `0142a71af4cb`** from one deploy in July. `run_burst.sh` hardcoded both the Pi's
IP and an absolute home path. **436 lines** `[loadtest/]`

✅ `delete:` **`DELETE /api/admin/pastes?last=N` — nobody calls it.** Not a CLI convenience either:
`Admin.js:92` carries the comment *"No bulk endpoint exists, so delete each item from the IP one
request at a time"* — the frontend author didn't know it had shipped. Deleted the handler, the route,
and `db.deleteRecentPastes`. **~52 lines + 1 file** `[endpoints/admin/deleteRecentPastes.nim, db.nim:187-205]`

✅ `delete:` **4 npm dependencies with zero imports anywhere in `src/`** — `@testing-library/jest-dom`,
`@testing-library/react`, `@testing-library/user-event`, `web-vitals`. There is no test file and no
`setupTests.js` in the tree. Also added the missing `devDependencies` block and moved `react-scripts`
into it, so the image build stops installing the dev tree as runtime deps. `npm ci` now removes 63
packages. `[pastebin-frontend/package.json]`

✅ `delete:` **`webframework/examples/hello.nim` + `defaultResolveIp` + `defaultConfig`.** Never built
by any Dockerfile or Taskfile target, and its `import ../server` contradicted the package-style import
the API uses. `defaultResolveIp` was a second, divergent copy of the XFF logic — a duplicate of exactly
the code that caused the fixed Funnel client-IP bug. `resolveIp` and `config` are now required
parameters. **~30 lines** `[webframework/examples/hello.nim, server.nim:33-43]`

✅ `delete:` **`NETWORK_LOG` and everything hanging off it.** Defaulted to `true`, no compose file set
it, and its `NETLOG method path` stdout line was a strictly poorer duplicate of `accesslog.nim`'s
`ts ip method path status ms`. Removing it killed `gNetworkLog`, `entry`, `gDispatch` and `serveRaw`
(`serve` now calls `listenAndServe` directly). **~24 lines** `[webframework/server.nim]`

✅ `delete:` **`docker-compose.yaml` — the documented local build could not work.** `context:
./pastebin-api` while `pastebin-api/Dockerfile:39-41` does `COPY webframework`, `COPY common`, and
`COPY pastebin-api/src` — none of which resolve under that context. README's `docker compose up
--build` had been broken since the webframework extraction. Fixed to `context: .` +
`dockerfile: pastebin-api/Dockerfile`, matching the `-f pastebin-api/Dockerfile .` that `task build`
already uses. `[docker-compose.yaml:8-10]`

> **Bug this had been masking.** With the build fixed, the stack came up and the API crashed on
> startup: `cannot open: /data/logs/access.log`. `pastebin-api/Dockerfile:68` created and chowned
> `/data/blobs` and `/data/db` but **not** `/data/logs`, so Docker created that mountpoint as
> `root:root` and the non-root (1654) container could not write to it. Production never hit it
> because `task deploy` creates the bind-mount dir on the host with the right ownership. Fixed by
> adding `/data/logs` to the `mkdir -p`. Out of the audit's stated scope, but it blocked the fix
> above from actually delivering a working local stack. Verified: full `docker compose up` now
> serves the SPA, creates/reads pastes, accepts uploads, and writes `access.log`.

⬜ `delete:` **Unused framework surface** — `put`/`patch` verbs, the three 2-param binding templates,
the 1-param `post` template, `onNotFound` (always nil, so `server.nim`'s nil-check is dead), `bodyLen`
(zero callers; its doc cites a guard that no longer exists), and the `Ctx` accessors `header`,
`queryParam`, `origin`, `remoteAddress` (zero callers — every handler goes through `ctx.req.header`).
**~35 lines** `[routetable.nim:26-65, context.nim:26-40, httpserver.nim:78-82]`
*Deliberately skipped in this pass at your request.*

---

## Tier 2 — near-duplicates kept apart only by having two URLs ⬜

Findings 1–4 are ~167 lines and all the same shape: two nearly identical handlers held apart because
they answer different paths. Routes are cheap; handlers aren't. Point several routes at one handler.

⬜ `shrink:` **`uploadFile` + `uploadFolder` are the same handler twice** — parse multipart → collect
parts → size check → quota → blob → `insertFile` → `notifyFileUploaded` → `storedFileJson`, differing
only in `saveFromFile` vs zip-then-`saveFromString`. One `handleUpload` collecting every `e.isFile`
part, branching once on `files.len == 1 and folderName.len == 0`; register both routes to it so the
frontend is untouched. **~75 lines (147 → ~70)**

⬜ `shrink:` **Merge `routetable` + `middleware` + `dispatcher` + `server` into one file.**
`dispatchRequest` has exactly one caller, `runChain` exactly one, and `RouteTable` is consumed only by
`serve`. 216 lines — 60 of them doc-comments justifying each file's separate existence — → ~80.
**~135 lines**

⬜ `shrink:` **`createPasteFromFile` is `createPaste` with a different content string** — identical
JSON parse, title/visibility read, `createPasteRecord` call, `{"id"}` response, and identical 413/429
except-arms. Fold into `handleCreatePaste` and point the route at it. **~20 lines + 1 file**

⬜ `shrink:` **`viewFile` is `downloadFile` minus one header**, and `DownloadData` exists only to carry
3 fields ten lines. One private `respondBlob(ctx, id, attachment: bool)`; two 1-line public handlers.
**~20 lines + 1 file + 1 type**

⬜ `shrink:` **The `PayloadTooLargeError → 413 / CacheFullError → 429 + Retry-After` block is
copy-pasted into four handlers.** One app-level `Middleware[AppConfig]` registered beside the access
log — `apperrors.nim:3-5` already documents this as the intended design, it's just spelled four times
instead of once. **~15 net lines**

⬜ `native:` **The `createObjectURL` / `createElement('a')` / `click()` / `revokeObjectURL`
blob-download dance, duplicated verbatim in two files.** Replace each with
`<a href={`/api/files/${id}/download`} download>` — the API already sends `Content-Disposition:
attachment` (`downloadFile.nim:33`), and `TextPasteView.js:41` already does exactly this. **~42 lines**
plus the `downloading` state and the `responseType:'blob'` axios usage.
`[App.js:365-385, FilePasteView.js:15-38]`

⬜ `shrink:` **`handleFileUpload` and `handleFolderUpload` are ~85% identical.** One
`uploadTo(url, formData, label)` with the two callers passing only the endpoint and content template.
**~45 of 112 lines** `[App.js:166-278]`

⬜ `delete:` **`FileInfo` in `App.js` duplicates the `.file-info` block in `FilePasteView.js`** — same
image-preview anchor, same Name/Size/Type/Uploaded/File-ID grid, same markup. **~30 lines**

---

## Tier 3 — hand-rolled stdlib

✅ `stdlib:` **`json.nim`'s `serialize` macro — 41 lines of AST construction, replaced by `std/json`'s
`%`.** `%` already walks an object's `fieldPairs` and maps each Nim field name straight to a JSON key,
renders the string-valued `Visibility` enum natively (so the custom `` `%`(Visibility) `` went too),
and `%` over a `seq` gives the array form — which retired both hand-rolled `newJArray` loops. `omit=`
became one `delete` call. One wrinkle: `%` won't compile against the `distinct string` `BlobId`, so a
one-line `` func `%`(b: BlobId) `` shim remains. Half the macro's output (`pasteNode`,
`storedFileNode`) was generated and never called. Verified byte-identical wire output including field
order. **~80 lines** `[pastebin-api/src/json.nim + 4 call sites]`

✅ `stdlib:` **`webframework/tmpfile.nim` → `std/tempfiles.genTempPath`.** The module's premise — *"Math.random-style entropy isn't available here"* — was simply false. **15 lines, whole file**

✅ `stdlib:` **`addBytes` (httpserver) and `appendTo` (multipart) — two near-identical hand-rolled
`setLen`+`copyMem` string appenders in two files → `std/strbasics.add`.** Imported as
`from std/strbasics import add`, since strbasics also exports a colliding `strip`. **~10 lines**

✅ `stdlib:` **`blobstore`'s `randomHex` nibble loop → `std/strutils.toHex`.** **~7 lines**
(smaller win than estimated: `urandom` returns `seq[byte]`, which `toHex(string)` won't take, so the
buffer is filled in place via the `openArray[byte]` overload.)

✅ `stdlib:` **`ntfy`'s `formatSize` → `std/strutils.formatSize(prefix = bpColloquial)`.** Output is
effectively identical ("50 MB", "1.5 kB", "512 B"); only the `KB`/`kB` casing differs. **13 lines**

✅ `native:` **`timeAgo` and `rateLimitMessage` reimplemented `Intl.RelativeTimeFormat`**, including
hand-rolled pluralisation and minute/second branching. Now only the unit is chosen locally. **~15 lines**
`[utils/format.js:16-25, App.js:23-29]`
**Wording changes slightly:** `just now` → `now`, `5min ago` → `5 minutes ago`, `1d ago` → `yesterday`.
Grammatically correct and locale-ready, but more verbose — revert if the terse form was deliberate.

⬜ `stdlib:` **`(x / 1024).toFixed(2) + ' KB'` written inline at 4 sites while `formatBytes` sits
imported in the same files.** Also fixes a 40 MB file reading as "40960.00 KB".
`[App.js:137,201,262, FilePasteView.js:89]`

⬜ `native:` **`Object.groupBy(pastes, p => p.ownerIp || 'unknown')`** replaces the `reduce`-into-object
IP grouping. **~7 lines** `[Admin.js:117-125]` — check against the `>0.2%` browserslist target first.

⬜ `native:` **Hidden `<input type=file>` + `getElementById().click()` + a `ref` callback to set
`webkitdirectory`.** Wrap each input in a `<label>` — the browser opens the picker with no JS, no DOM
ids, no ref hack; `webkitdirectory` is a valid JSX attribute in React 18, so the comment at
`App.js:89-90` is stale. `accept="*/*"` is also the default. **~12 lines** `[App.js:82-114]`

---

## Tier 4 — flexibility nobody uses ⬜

⬜ `yagni:` **The generic app-state type `E` — 94 `[E]` occurrences, one real instantiation**
(`AppConfig`; the only second one was the demo file, now deleted). Binding it concrete also retires the
`serve[E]` + `var gRun {.global.}` nimcall-thunk dance. Same for `Router[P]`, where `P` is only ever
`Handler`. **~30 lines**

⬜ `yagni:` **`common/templates.nim` and the `common/` directory.** `referencing` (51 uses) aliases
`from m import nil`; `returnif` (14 uses) aliases `if cond: return` — both save zero characters while
hiding a control-flow `return` behind something that reads like a call. `swallowException` has one use.
`referencing` also forces bare module names, which is the only reason `--path:"src"` exists. That
leaves `getOr404`, which belongs in `webframework/context.nim` beside `parseJsonBodyOr400` —
`context.nim:43-44` already says so. **~35 lines + one top-level project**

⬜ `yagni:` **Taskfile's `PI_DATA_DIR`-or-`DATA_UUID` dual resolution, open-coded three times**
(`setup` L70-79, `deploy` L136-145, `funnel` L176-184). `.taskenv` only ever sets `DATA_UUID`;
`PI_DATA_DIR` has never been used. One `findmnt -rno TARGET -S UUID=$DATA_UUID` line replaces all
three. **~45 lines** `[Taskfile.yml, .taskenv.example]`

⬜ `yagni:` **Dead config knobs.** `INLINE_PASTE_MAX_BYTES` and `CACHE_MAX_BYTES` are set by nothing
anywhere — not `.env.example`, neither compose, not the Dockerfile, not the Taskfile. Make them consts
at their use sites, as CLAUDE.md already prescribes for `pastePreviewChars`.
`ACCESS_LOG_MAX_BYTES` / `ACCESS_LOG_FLUSH_MS` / `NTFY_SERVER_URL` are only ever passed as
`${X:-<the code default>}` — pure passthrough noise. **~20 lines**

⬜ `shrink:` **`.env.example` is a third copy of defaults that already live in `config.nim` and both
compose files.** Every var has a baked-in default, so it only needs the values with *no* usable
default: `TS_AUTHKEY`, `ADMIN_TOKEN`, `DB`/`BLOB`/`LOG_HOST_PATH`, `PUBLIC_BASE_URL`, `NTFY_TOPIC` —
plus a pointer to `config.nim`. **~40 lines**

⬜ `delete:` **`db.nim`'s `columnExists` / `addColumnIfMissing` + the four migration calls.** The two
`visibility` ones are already dead — `CREATE TABLE` at `:73` and `:85` declares the column. The
`owner_ip` two are load-bearing only because `owner_ip` was left out of `CREATE TABLE`; add it there
and all four go. Production migrated long ago. **~20 lines** `[db.nim:37-47,90-93]`

⬜ `yagni:` **`?limit=` on `/api/pastes` and `/api/admin/access-log`** — zero callers pass either; the
UI takes the default every time. Cutting both plus `clampedQueryInt` saves **~12 lines**. If you keep
one, keep `/api/pastes` (plausible curl use).

⬜ `shrink:` **Four files that are mostly ceremony:** `quota.nim` (17 lines for a 4-line proc with one
DB call), `apperrors.nim` (2 type lines under a 5-line header), `timeutil.nim` (2 one-liners under 8),
`clientip.nim` (15 of 23 lines are header/imports, and it pulls in `std/sequtils` to `filterIt` a
freshly-allocated 4-element seq on every request). Fold each into its only caller. **~55 lines + 4 files**

⬜ `delete:` **`pastebin-api/build.sh` — dead.** Nothing invokes it: the Dockerfile does its own
cross-compile, the Taskfile only calls `docker buildx`, and CLAUDE.md documents local builds as plain
`nim c`. **13 lines**

⬜ `native:` **nginx `error_page 500 502 503 504 /50x.html` + its `location` block.**
`/usr/share/nginx/html` is fully replaced by the CRA build, which contains **no `50x.html`** — so every
error page is an internal 404 today and nginx's built-in body is what actually renders. Notably this
means the edge-shed 503 serves a broken error page. **6 lines** `[nginx.conf:107-112]`

⬜ `shrink:` **nginx `upstream backend { }` + `X-Forwarded-Proto` + `proxy_http_version 1.1`.** One
server, no `keepalive`, no failover → identical to `proxy_pass http://pastebin-api:8080/api/;` inline;
`proxy_http_version 1.1` only matters with an upstream `keepalive`, which is absent; nothing in
`pastebin-api/src/` or `webframework/` ever reads `X-Forwarded-Proto`. **6 lines**

⬜ `shrink:` **`expose: "8080"` in both compose files** — a documentation-only no-op under Compose v2
(the port is reachable on the shared bridge regardless; only `ports:` publishes). **4 lines**

---

## Tier 5 — the biggest single number ⬜

⬜ `delete:` **Create React App / `react-scripts` 5.0.1** — last released April 2022, officially
deprecated February 2025. Nothing in `src/` uses a CRA-specific API (no `process.env.REACT_APP_*`, no
CSS-module or SVG imports); the only coupling was the `eslintConfig` and `browserslist` blocks. Vite +
`@vitejs/plugin-react` with `build.outDir: 'build'` keeps `nginx/Dockerfile:19` unchanged. Move
`public/index.html` to the project root with a `<script type="module" src="/src/index.js">`, add
`vite.config.js`, swap the scripts. **~1,200 of ~1,384 locked packages; `node_modules` ~394 MB → ~60 MB.**
Roughly 30 minutes of work.

Lower-confidence companions, listed for completeness:

- ⬜ `stdlib:` **`axios` → `fetch`** for 8 call sites. The genuine blocker is `onUploadProgress`
  (`App.js:185,249`) — `fetch` has no upload progress, so keeping the % bar needs ~15 lines of raw
  `XMLHttpRequest`. **1 dep.**
- ⬜ `yagni:` **`react-router-dom` for 4 flat routes** with zero `<Link>`, `<Outlet>`, `useLocation`,
  `useSearchParams` or nesting — only `useNavigate` and `useParams` are touched. ~15 lines of
  `popstate` + `pushState` replaces it. **1 dep (~20 KB gz).** Cut only if bundle size matters; the dep
  is at least fully used for what it does.
- ⬜ `delete:` **`import React from 'react'` in 5 files that never reference `React.*`** — both
  react-scripts 5 and Vite use the automatic JSX runtime. Keep it in `index.js`, which uses
  `React.StrictMode`.
- ⬜ `delete:` **70 lines of untouched CRA boilerplate README** documenting `npm run eject`,
  code-splitting and PWA sections this project will never use. `[pastebin-frontend/README.md]`

---

## Deliberately not cut

- **`pastecache`'s LRU read-cache half.** Dropping the clean/LRU machinery and keeping only the dirty
  write buffer would save ~105 lines including tests, but that's a real performance trade-off on a
  900 MB Pi, not dead weight. Out of scope for a complexity audit — decide it separately, on measurements.
- **`guard.nim`'s escalating lockout and `constantTimeEq`.** Security boundary; the nearest stdlib
  alternative is a new dependency, which costs more than the 8 lines it would save.
- **`accesslog.nim`'s buffered writer + ever-increasing rotation.** No stdlib equivalent, and the
  never-delete policy is a deliberate decision documented in CLAUDE.md.
- **`formatBytes`.** `Intl.NumberFormat` has no auto-scaling byte unit. Keep it — and start *using* it
  at the four sites that currently bypass it.
- **`index.css`.** All 42 class selectors are live; the two that fail a literal grep (`.alert-success`,
  `.alert-warning`) are built dynamically by `` `alert-${message.type}` `` at `App.js:41`. At 503 lines
  it is the least over-engineered file in the frontend. The four near-identical gradient/hover button
  blocks could collapse into a base class plus three overrides (~25 lines), but that is taste, not dead code.
- **`db.nim`'s `int64OrZero`** — 12 call sites, real duplication saved.
- **`BlobId` as `distinct string`.** Costs a `{.borrow.}` `len`, four `.string` casts and the one-line
  `%` shim, but it does prevent a real id-swap bug between the SQLite key and the filesystem key.
- **Contested — `contentDispositionAttachment`'s hand-rolled percent-encoding.** One reviewer proposed
  `std/uri.encodeUrl(usePlus = false)`; another argued it would mangle non-ASCII filenames. The first is
  right — `encodeUrl` escapes a strict superset of RFC 5987 attr-char, so the output stays valid — but
  it's 10 lines on a correctness-sensitive path. Low priority.

---

## Stale documentation found along the way

All fixed in this pass except where noted:

- ✅ `CLAUDE.md:23` advertised four `docs/` files that don't exist (`SECURITY.md`, `PERFORMANCE.md`,
  `NTFY_NOTIFICATIONS.md`, `visibility-plan.md`).
- ✅ `README.md:78` linked `docs/plans/`; the real path was `docs/superpowers/plans/`.
- ✅ `.env.example:52` still called `WORKER_THREADS` "the **Mummy** worker-thread pool" — Mummy was
  replaced by the hand-rolled `webframework`.
- ✅ `CLAUDE.md:93` listed a `webframework/macros.nim` that isn't in the tree.
- ✅ CLAUDE.md described a "one-shot legacy-ISO migration" in `timeutil.nim`; that code no longer
  exists — the file is 12 lines with no migration.
- ⬜ `webframework/dispatcher.nim:13` and `webframework/nim.cfg:8` cite a `bench/` directory that isn't
  anywhere in the repo, as the justification for the closure-free dispatch design.
- ⬜ `docker-compose.rpi.yaml:52` cites two of the same missing docs.

---

## Net

| | Removable | Applied this pass |
|---|---|---|
| Nim / JS source | ~920 lines (~16%) | ~310 lines |
| Docs, loadtest, compose | ~2,450 lines | ~2,090 lines |
| Tracked binary | 1.39 MB | 1.39 MB |
| npm dependencies | 6 | 4 (+63 packages via `npm ci`) |
| npm transitive packages | ~1,200 (via Vite) | — |

**net: -920 lines of code, -2,450 lines of non-code, -1.39 MB tracked, -6 deps possible.**

The two findings that are more than cleanup: the **rate limiter had never fired in production**, and
**local `docker compose up --build` had been broken since the webframework extraction** despite the
README documenting it as the way to run the stack. Both are now fixed.
