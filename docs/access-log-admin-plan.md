# Show the access log as a list on the admin page

## Context

The API writes one plaintext line per request to a rotating access-log file
(`accesslog.nim`): `timestamp ip method path status durationms`. It is buffered in RAM
and flushed to disk every ~5s by a background thread. Today there is **no HTTP read
path** — the only way to see it is to SSH to the Pi and read the file.

Goal: surface recent access-log entries as a list inside the existing `/admin` page so
they can be viewed in the browser (admin-only).

**Decisions made with the user:**
- **Keep the flat-file storage as-is** — no change to save location, no SQLite table.
  The API process writes the file, so it simply reads it back. This preserves the
  deliberate memory-lean, append-only, cron-pruned design described in CLAUDE.md.
- **Surface it as a tab within `/admin`** (not a separate route), reusing the existing
  token-prompt/auth logic in `Admin.js`.

## Log persistence across deploys & shutdowns

The admin read view is only useful if the file it reads survives a redeploy and a reboot.
This **already holds today** — access-log storage is wired exactly like the DB and blobs, so
no code change is needed for the read feature. Confirm (don't re-implement) the following, and
treat any gap as a bug to fix before shipping the view:

- **Production (`docker-compose.rpi.yaml`)** — `/data/logs` is a **bind-mount** from
  `${LOG_HOST_PATH}` (`$BASE/logs` on the btrfs data disk), alongside `blobs`/`db`. The log file
  lives on the host disk, not in the container's writable layer, so it is untouched when the
  container is recreated.
- **Across deploys** — `task deploy` recreates only the API container from the new image; the
  bind-mounted host dir is never touched. `Taskfile.yml` also `mkdir -p`s + `chown 1654:1654`s
  `$BASE/logs` every deploy (idempotent), so a fresh Pi/data-disk still gets a writable log dir.
- **Across shutdowns/reboots** — the data disk is in `/etc/fstab` with `nofail` and
  `docker.service` has `After=…<data-uuid>.mount`, so Docker waits for the disk before starting
  the API (no empty-dir race). The rotation scheme is append-only with ever-increasing suffixes
  and never renames existing files, so it resumes cleanly after a restart.
- **Local dev (`docker-compose.yaml`)** — `/data/logs` is the named `log-data` volume, which
  persists across `docker compose up`/`down`/restart. Only `docker compose down -v` wipes it
  (expected — that flag deletes db/blobs too).
- **Accepted loss window (unchanged)** — the ~5 s in-memory buffer means a *hard* crash can lose
  the last few seconds of lines. This is the existing documented trade-off; the read view's
  forced flush (below) does not change it.

⚠️ The one gotcha shared with db/blobs: if the data disk ever fails to mount, `nofail` lets Docker
start against an empty SD-card dir and the log restarts empty (real logs stay safe on the
unmounted disk). Same failure mode as the DB — see CLAUDE.md → "RPi runtime & restart survival".

**Verification (persistence):** with the prod-style bind-mount, generate traffic, then
`docker compose -f docker-compose.rpi.yaml up -d --force-recreate pastebin-api` and re-hit
`/api/admin/access-log` — the pre-recreate lines must still be present. `ls $LOG_HOST_PATH` on
the host should show `access.log` (+ any `access.log.N`) owned by `1654:1654`.

## Backend — `pastebin-api/`

### 1. Add a read accessor to `src/accesslog.nim`

Expose the newest lines, including buffered-but-not-yet-flushed ones, so the view isn't
up to 5s stale and shows the admin's own recent requests. Add to the public API section:

```nim
proc recentLines*(limit: int): seq[string] =
    ## Newest-first lines of the active log. Forces a flush first (under gLock) so buffered
    ## lines are included and there's no file/gBuf duplication race. Admin-only + infrequent,
    ## so holding the lock across the small (<=5 MB) file read is acceptable.
    returnif: not gEnabled          # disabled => @[]
    var content: string
    withLock gLock:
        flushBuffer()
        content = readFile(gPath)
    var lines = content.splitLines()
    if lines.len > 0 and lines[^1].len == 0: lines.setLen(lines.len - 1)  # drop trailing ""
    let startIdx = max(0, lines.len - limit)
    for i in countdown(lines.len - 1, startIdx): result.add lines[i]       # newest first
```

Notes:
- `gEnabled`/`gPath` are set once at init, safe to read outside the lock; the `readFile`
  stays inside so it can't interleave with a flush/rotate.
- Reads only the **active** file. The rare case right after a size-rotation (active file
  nearly empty, older lines in `access.log.N`) yields fewer lines — acceptable for a
  "recent" view and consistent with CLAUDE.md treating rotated files as external concern.

### 2. New handler `src/endpoints/admin/listAccessLog.nim`

Mirror `listPastes.nim` / `recentPastes.nim`. Parse each space-delimited line; the
**timestamp itself contains a space** (`date time`), and paths are URL-encoded (no spaces),
so a plain `split(' ')` yields exactly 7 tokens.

```nim
## GET /api/admin/access-log — most recent access-log lines, newest first (admin only).

import std/[json, strutils]
import ../routes, guard
importuse accesslog

const
    DefaultLimit = 200
    MaxLimit = 1000

proc handleAdminAccessLog*(ctx: Ctx) =
    returnif: not ctx.requireAdmin()
    var limit = DefaultLimit
    let lp = ctx.req.queryParam("limit")
    if lp.len > 0:
        try: limit = parseInt(lp)
        except ValueError: limit = DefaultLimit
    limit = max(1, min(limit, MaxLimit))

    var arr = newJArray()
    for line in accesslog.recentLines(limit):
        let p = line.split(' ')
        if p.len < 7: continue                          # skip malformed lines
        arr.add %*{
            "timestamp": p[0] & " " & p[1],
            "ip": p[2],
            "method": p[3],
            "path": p[4],
            "status": p[5],
            "duration": p[6],                            # e.g. "12ms"
        }
    ctx.req.respond(200, $arr)
```

Build the JSON ad-hoc with `%*{...}` (as `deletePaste.nim` does) rather than the
`serialize` macro — `method` is a Nim keyword and can't be a plain field name, and
ad-hoc keeps wire keys fully under our control. `status`/`duration` are sent as the raw
strings; the frontend parses `status` for coloring.

### 3. Register the route in `src/endpoints/routes.nim`

- Add `admin/listAccessLog` to the handler import list (line ~34).
- Add under the admin block (line ~53):
  ```nim
  result.get("/api/admin/access-log", handleAdminAccessLog)
  ```

## Frontend — `pastebin-frontend/src/pages/Admin.js`

Add an in-page tab. Reuse the existing `authHeader()` / `handleAuthError()` /
`sessionStorage` token flow and the `recent-pastes` / `recent-paste-item` / `paste-meta`
list styling (no CSS changes needed).

- Add state: `view` (`'content' | 'accesslog'`), `logEntries`, and reuse `loading`/`error`.
- Add `loadAccessLog` (a `useCallback`, mirroring `loadPastes`) calling
  `axios.get('/admin/access-log', { headers: authHeader() })`.
- In the header `paste-actions`, add two toggle buttons — **Content** and **Access log** —
  in the same disabled-when-active style as the existing Flat / By IP buttons. Switching to
  the Access-log tab triggers `loadAccessLog()` (lazy load); Refresh reloads the active tab.
- When `view === 'accesslog'`, render `<ul className="recent-pastes">` of
  `<li className="recent-paste-item">` (keyed by index), each a single `paste-meta` line:
  `timestamp · ip · method · path · status · duration`, with `status` colored (2xx green,
  ≥400 red) via an inline `style` like the existing visibility color. Handle empty
  (`alert alert-info`, "No access-log entries.") and the disabled case (empty array → same
  empty message).

Keep the Flat / By IP toggle and delete actions scoped to the Content tab only.

## Verification (local dev, no Docker)

1. Type-check: `cd pastebin-api && nim check --hints:off src/main.nim` (exit 0 = clean).
2. Build + run e2e with the access log enabled:
   ```
   nim c -o:/tmp/pb src/main.nim
   SQLITE_PATH=/tmp/pbd/db.sqlite BLOB_STORAGE_PATH=/tmp/pbd/blobs PORT=18080 \
   ADMIN_TOKEN=secret ACCESS_LOG_PATH=/tmp/pbd/access.log \
   ACCESS_LOG_FLUSH_MS=500 NETWORK_LOG=false /tmp/pb &
   ```
3. Generate traffic, then read the log endpoint:
   ```
   curl -s http://127.0.0.1:18080/api/pastes >/dev/null
   curl -s -X POST http://127.0.0.1:18080/api/pastes \
     -H 'Content-Type: application/json' -d '{"content":"hi"}' >/dev/null
   curl -s -H 'X-Admin-Token: secret' http://127.0.0.1:18080/api/admin/access-log | jq .
   ```
   Expect a JSON array, newest first, with `timestamp/ip/method/path/status/duration`
   fields — including the just-issued requests (proves the forced-flush accessor works).
4. Auth: same call without `X-Admin-Token` → 401; with a wrong token → 401 (then the
   escalating-lockout 429 on repeat), confirming `requireAdmin` guards it.
5. Frontend: `cd pastebin-frontend && npm start`, open `/admin`, enter the token, click
   **Access log** → list renders; **Refresh** reloads it; **Content** switches back.
