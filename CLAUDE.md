# Pastebin

A full-stack pastebin for sharing text snippets and files. Built to run on a **Raspberry Pi 3B
behind CGNAT**, so the whole design is memory-lean and exposed publicly via **Tailscale Funnel**
(no port-forwarding, no TLS cert on the box). Metadata lives in embedded **SQLite**; file/large-paste
**blobs** live on the filesystem (a dedicated **btrfs data disk** in production — see Gotchas).

## Architecture

```
public ──HTTPS──▶ Tailscale Funnel edge ──HTTP──▶ nginx :80 ──▶ pastebin-api :8080
                  (terminates TLS)                (static SPA      (Nim, SQLite + blob store)
                                                   + /api proxy)
```

- **`pastebin-api/`** — **Nim backend, the deployed one.** Source of truth for all limits,
  quotas, and storage. (Originally a port of a .NET backend, since removed — see Backend below.)
- **`pastebin-frontend/`** — React 18 SPA (Create React App / `react-scripts`). `npm run build` → static `/build`.
- **`nginx/`** — Reverse proxy + static serving. Serves the built SPA, proxies `/api/*` to the API,
  sets `X-Real-IP`/`X-Forwarded-For`, applies `security-headers.conf`. Serves **plain HTTP on :80** —
  TLS is terminated upstream by Funnel, so do NOT add an HTTPS redirect (it would loop).
- **`Taskfile.yml`** — deploy automation (`task --list`; see Deploy below).
- **`docs/`** — `SECURITY.md`, `PERFORMANCE.md`, `NTFY_NOTIFICATIONS.md`, `visibility-plan.md`.
- **`rpi-omv-setup.md`** — detailed reference for the physical Pi / OpenMediaVault box.

## Code conventions

- **Keep a feature together.** All the code for one feature lives in a single file, or — when it
  spans layers — in a single **vertical slice** (controller → service → store for that feature).
  Don't scatter one feature's logic across unrelated files.
- **Follow the existing onion structure.** Dependencies point inward (controllers → services →
  stores/domain), never the reverse. New code slots into the current layering; don't invent a
  parallel structure.
- **Reuse before you write.** Prefer the standard library and existing common/shared helpers over
  hand-rolled equivalents. Don't reinvent what already exists — simpler, cleaner code wins.
- **Comment the non-obvious, not the obvious.** The code is mostly self-explanatory — don't narrate
  what it plainly does. Do add a concise comment where a concept or gotcha isn't obvious, or where a
  high-level detail needs describing (the *why*, an invariant, a subtle edge case).
- **Public API first, private helpers last.** In a handler file, order top-to-bottom: `const` blocks
  and template/macro invocations (e.g. `serialize(...)`), then the public handler, then private
  helper procs/funcs at the bottom. Since Nim requires declaration-before-use, add a one-line forward
  declaration near the top for any private helper a public proc calls.

## Backend (`pastebin-api/`) — the deployed one

The Pi runs this **Nim** backend (`task build` builds `pastebin-api/Dockerfile`). It began as a
drop-in port of a .NET backend, but that .NET tree has been **deleted**, and the Nim backend has
since **deliberately diverged** from the old .NET wire/storage format to simplify itself (epoch-millis
timestamps instead of .NET `"o"` text, `""` instead of JSON `null` for empty `contentType`, base62
IDs, `{"id"}`-only create responses). Edit the Nim tree to change runtime behavior. Onion
structure under `pastebin-api/src/`:

- `main.nim` — entrypoint/wiring. `config.nim` — env-var limits + defaults, incl. the 3-tier rate
  limits and `uploads` policy. A few never-tuned limits (`maxRequestBytes` 1 GB, `pastePreviewChars`,
  `untitledTitleMaxChars`) are fixed constants, not env vars.
- **`endpoints/routes.nim` — the route map** (verb → path → handler). Start here to find any
  endpoint. One handler per file under `endpoints/{pastes,files,admin}/`: createPaste,
  rawPaste (`/api/pastes/{id}/raw` streams full text), recentPastes, getPaste; uploadFile,
  uploadFolder (folder→zip), downloadFile, viewFile, createPasteFromFile, getFile, deleteFile;
  admin listPastes/deletePaste (+ `guard.nim`).
- Services: `db.nim` (SQLite via `db_connector`; creates schema `pastes`+`files` on startup),
  `blobstore.nim` (blob store, 2-char sharding `ab/ab12…`, atomic temp→final writes, seekable/Range
  reads; `saveFromString` for inline-overflow, `saveFromFile` for uploads — paste content <256 KB
  stays inline in SQLite, larger → blob), `quota.nim` (per-IP cap `MAX_STORAGE_BYTES_PER_IP`,
  100 MB), `ratelimit.nim` (per-IP sliding window + global sliding window + global concurrency cap),
  `ntfy.nim`, `timeutil.nim` (Unix epoch-millis timestamps + one-shot legacy-ISO migration),
  `ids.nim` (8-char base62 public IDs for pastes/files), `types.nim`, `apperrors.nim`.
- `clientip.nim` — `resolveClientIp`, the client IP for **rate-limit + quota bucketing**. Uses the
  **first `X-Forwarded-For` entry**: Funnel sets XFF to the real public client (dropping any
  client-supplied XFF, so the leftmost hop isn't spoofable via the public path), then nginx appends
  the docker-bridge gateway → `"<client>, 172.18.0.1"`. `X-Real-IP` is nginx's `$remote_addr` (that
  constant gateway), a fallback only — preferring it (an old bug) collapsed every user into one bucket.
- `webframework/` — hand-rolled HTTP stack, no framework dep: `httpserver.nim` (`std/net`; streams
  bodies over the spill threshold to a temp file; Range support), `router.nim`, `multipart.nim`
  (custom parser), `dispatcher.nim`, `middleware.nim`, `context.nim`, `server.nim`. Optional
  per-request `NETLOG` stdout line for IP-chain debugging (disable with `NETWORK_LOG=false`).
- `pastebin.nimble` — deps: `db_connector`, `zippy` (folder→zip); needs `nim >= 2.0`.

Local dev (no Docker; `nim` is on PATH at `~/.nimble/bin/nim`):
- Type-check: `cd pastebin-api && nim check --hints:off src/main.nim` (exit 0 = clean).
- Build: `nim c -o:<out> src/main.nim`.
- Run e2e: `SQLITE_PATH=<dir>/db.sqlite BLOB_STORAGE_PATH=<dir>/blobs PORT=18080
  ADMIN_TOKEN=<tok> NETWORK_LOG=false <binary>`, then curl `http://127.0.0.1:$PORT/api/…`.
  Blob paths (vs inline SQLite) trigger at paste content >256 KB and on any file upload.

## Deploy

Never build on the Pi (900 MB RAM thrashes). Cross-build arm64 images on a fast workstation, push
them to a **Docker registry running on the Pi**, and have the Pi pull only the changed layers. This
is all driven by **`Taskfile.yml`** (`task --list` for the menu):

- `task setup` — one-time: start the `pastebin-registry` container on the Pi (storage on the btrfs
  data disk) + create a local `buildx` builder that trusts the Pi's plain-HTTP registry.
- `task` (= `task build` + `task deploy`) — normal release: `buildx --platform linux/arm64 --push`
  the API + nginx images to `<pi-ip>:5000`, then SSH to the Pi to `docker compose pull` + `up -d`
  (the Pi pulls from its own `127.0.0.1:5000`, trusted-insecure by default under `127.0.0.0/8`).
- `task funnel` — one-time: install Tailscale on the Pi and expose the site via Funnel (idempotent).
- `task ps` / `task logs` — status / follow the API logs on the Pi.

Auth is hands-free: the Pi password lives in **`.taskenv`** (gitignored, `PI_PASS=<pi-password>`) and `ssh`/`scp`
are `sshpass`-wrapped; leave `PI_PASS` empty to use an SSH key instead.

**Deploying off-LAN (over Tailscale).** `.taskenv` pins `PI_IP` to the LAN address (`192.168.0.30`);
when the workstation isn't on the Pi's LAN, deploy over the tailnet instead — the Pi is `rpi`
(`100.120.214.111`) and its registry (`:5000`) + SSH (`:22`) are reachable there. Steps: (1) start
`tailscaled` locally (`sudo systemctl start tailscaled` — needs the user's sudo password); (2) recreate
the buildx builder to trust the **tailnet** registry (the builder's insecure-registry trust is pinned
to one `host:port`, so the LAN builder won't push over tailnet): rebuild `pastebin-builder` with a
config TOML for `100.120.214.111:5000` — same commands as `task setup`'s second step; (3) override the
IP on every task call: `task PI_IP=100.120.214.111 build` then `task PI_IP=100.120.214.111 deploy`
(also `ps`/`logs`). The Pi still pulls from its own `127.0.0.1:5000`, so nothing else changes. The data disk is located by
filesystem **UUID** (`<data-uuid>`), not mount path, since OMV mounts it at `/srv/dev-disk-by-uuid-<uuid>`.

- **Build stages run natively, not emulated.** Both Dockerfiles pin their build stage to
  `FROM --platform=$BUILDPLATFORM …` (the workstation's amd64) and target arm64 only for the final
  runtime image. The React build is static JS (arch-neutral). The Nim API build stays QEMU-free by
  compiling Nim→C natively on amd64, then cross-compiling that C to arm64 **glibc** with `zig cc`
  (glibc, not musl, so the runtime's `dlopen` of libsqlite3/openssl works — see the Dockerfile
  header). **Don't drop the `--platform=$BUILDPLATFORM` pins** or the heavy steps run under emulation
  again (minutes slower).
- **Only changed layers cross the wire.** The registry lives ON the Pi (the always-on box with a
  stable address; the build machine is on WiFi/DHCP). `buildx --push` sends only new layers, so
  steady-state deploys are ~15 s. `--provenance=false --sbom=false` skips attestation manifests
  (they turn each image into a multi-manifest index and dominated the first push's ~500 MB / ~4 min).
- Public URL: **https://<host>.<tailnet>.ts.net/**. SSH: `pi@<pi-ip>` (OpenMediaVault box).

**Compose files:** `docker-compose.yaml` (local dev, named volumes; nginx on `:80`, override
via `PASTEBIN_HTTP_PORT`), `docker-compose.rpi.yaml` (production: btrfs-disk bind-mounts, memory caps,
non-root user, log rotation, `Production` env, GC heap limit; images pulled from `${REGISTRY}`).

## RPi runtime & restart survival

The stack recovers on its own after a reboot — no manual `task deploy` needed (verified 2026-07-02):

- `docker` and `tailscaled` are both `systemctl enabled`.
- Containers carry restart policies — `deploy-pastebin-api-1` & `pastebin-nginx` = `unless-stopped`,
  `pastebin-registry` = `always`. Docker restarts the already-created containers from locally cached
  images, so the registry is **not** needed to restart the stack (only to deploy new images).
- The btrfs data disk is in `/etc/fstab` (`nofail`) and `docker.service` has `After=…<data-uuid>.mount`,
  so Docker waits for the disk before starting the containers — no empty-bind-mount race on a clean boot.
- Tailscale Funnel config persists (`tailscale funnel --bg`), so `https://<host>.<tailnet>.ts.net → :80`
  returns automatically.
- **WiFi failover**: the Pi is wired-primary but auto-connects to WiFi (`wlan0`) if `eth0` loses its
  carrier, and reverts when the cable returns — so an unplugged/dead ethernet link doesn't take the
  site down (Tailscale rides `wlan0`'s same-LAN IP). Driven by `wifi-failover.service` +
  `wifi-regdomain.service` + `/etc/netplan/90-wifi-failover.yaml`. See `rpi-omv-setup.md` → Network.
- ⚠️ `nofail` + `After=` (not `Requires=`): if the data disk ever *fails* to mount, Docker still starts
  and bind-mounts an empty SD-card dir → the API creates a **fresh empty DB**. Real data stays safe on
  the unmounted disk, but the site looks wiped until the disk is remounted and the containers restarted.

Box: Pi 3B, Debian 12 (bookworm), kernel 6.12 aarch64, 906 MB RAM / 512 MB swap, Docker 28.4.0 /
Compose v2.39.2, OpenMediaVault 7. OMV's web UI was moved off :80 → **:9000** so nginx can own :80.

## Gotchas

- SQLite uses WAL → the data dir must be a real POSIX filesystem (not FAT32/exFAT).
- nginx `client_max_body_size` and the API's `MAX_REQUEST_BYTES` must stay in sync (1 GB default).
- CORS: the API sets no `Access-Control-*` headers — the SPA is same-origin (relative `/api` base),
  so cross-origin browser access is blocked by default. (The old wildcard `AllowAll` in nginx, a
  leftover from the deleted .NET backend, has been removed.)
- Compose recreates the API container only when `pastebin-api:rpi` resolves to a new image ID;
  if a deploy is interrupted (e.g. Pi reboot mid-`docker load`), the image can land corrupt — re-ship.
- **Production data lives on the btrfs data disk `/dev/sdb` (UUID `<data-uuid>`, 30 GB),** which OMV
  mounts at `/srv/dev-disk-by-uuid-<data-uuid>/`. Everything the stack owns sits under `.../pastebin/`:
  `deploy/` (compose + `.env`), `db/` (SQLite), `blobs/`, and `registry/` (the on-Pi registry store).
  The Pi's `.env` pins `BLOB_HOST_PATH`/`DB_HOST_PATH` to this **by-UUID** path (not a friendly name)
  so the stack comes back on the right disk after a reboot.
- **`/mnt/usb` holds only a stale copy — nothing live reads from it.** It's a 7.5 GB ext4 stick
  (`/dev/sda1`, UUID `<usb-uuid>`) mounted outside OMV, leftover from an earlier layout: an old
  `db/`+`blobs/` copy and the old `pastebin-images-arm64.tar.gz`. (Older docs calling `/mnt/usb` the
  production store are outdated.)
- **A *different* btrfs disk (UUID `<omv-disk-uuid>`) is still missing.** OMV's own `shared`/`internal`
  shares and Pi-hole's data reference it, but it isn't attached, so *those* silently fall back to the
  SD-card rootfs. It is unrelated to the pastebin data disk (`<data-uuid>`) above — don't conflate them.
