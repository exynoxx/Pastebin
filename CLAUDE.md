# Pastebin

A full-stack pastebin for sharing text snippets and files. Built to run on a **Raspberry Pi 3B
behind CGNAT**, so the whole design is memory-lean and exposed publicly via **Tailscale Funnel**
(no port-forwarding, no TLS cert on the box). Metadata lives in embedded **SQLite**; file/large-paste
**blobs** live on the filesystem (a dedicated **btrfs data disk** in production — see Gotchas).

## Architecture

```
public ──HTTPS──▶ Tailscale Funnel edge ──HTTP──▶ nginx :80 ──▶ pastebin-api :8080
                  (terminates TLS)                (static SPA      (.NET 8, SQLite + blob store)
                                                   + /api proxy)
```

- **`pastebin-api/`** — .NET 8 C# backend. The source of truth for all limits, quotas, and storage.
- **`pastebin-frontend/`** — React 18 SPA (Create React App / `react-scripts`). `npm run build` → static `/build`.
- **`nginx/`** — Reverse proxy + static serving. Serves the built SPA, proxies `/api/*` to the API,
  sets `X-Real-IP`/`X-Forwarded-For`, applies `security-headers.conf`. Serves **plain HTTP on :80** —
  TLS is terminated upstream by Funnel, so do NOT add an HTTPS redirect (it would loop).
- **`Taskfile.yml`** — deploy automation (`task --list`; see Deploy below).
- **`docs/`** — `SECURITY.md`, `PERFORMANCE.md`, `NTFY_NOTIFICATIONS.md`, `visibility-plan.md`.
- **`rpi-omv-setup.md`** — detailed reference for the physical Pi / OpenMediaVault box.

## Backend components (`pastebin-api/`)

**Controllers** (`controllers/`)
- `PastesController` — create/fetch/list pastes; `/api/pastes/{id}/raw` streams full text.
- `FilesController` — single-file upload, multi-file folder→zip upload, create-paste-from-file.
- `DebugController` — `/api/debug/ip` diagnostic: echoes the caller's IP header chain
  (`resolvedClientIp`, `X-Forwarded-For`, `X-Real-IP`, …) to verify what reaches the API behind Funnel.

**Services** (`services/`)
- `PasteService` — inline pastes (<256 KB) stored in SQLite; larger ones go to the blob store.
- `FileUploadService` — writes uploads to the blob store, records `StoredFile` rows.
- `FileSystemBlobStore` (`IBlobStore`) — streams blobs to disk with 2-char sharding (`ab/ab12…gz`),
  atomic temp→final writes, seekable reads (HTTP range/resume).
- `SqliteConnectionFactory` — opens `SQLITE_PATH`, creates schema (`pastes`, `files`) on startup.
- `StorageQuota` — per-IP storage cap (`MAX_STORAGE_BYTES_PER_IP`, default 100 MB).
- `ClientIp.Resolve(context)` — resolves the client IP used for **rate-limit and quota bucketing**.
  Uses the **first `X-Forwarded-For` entry**: verified via `/api/debug/ip`, Funnel sets XFF to the
  real public client (and drops any client-supplied XFF, so the leftmost hop isn't spoofable via the
  public path), then nginx appends the docker-bridge gateway → `"<client>, 172.18.0.1"`. `X-Real-IP`
  is nginx's `$remote_addr` (that constant gateway), so it's only a fallback — preferring it (the old
  bug) collapsed every public user into one bucket. Same precedence in the Nim `resolveClientIp`.

**`program.cs`** — wires config (env-var overridable limits), 3-tier rate limiting (per-IP sliding
window, global sliding window, global concurrency cap) + an `uploads` policy, and an optional
per-request `NETLOG` stdout line for IP-chain debugging (disable with `NETWORK_LOG=false`).

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
are `sshpass`-wrapped; leave `PI_PASS` empty to use an SSH key instead. The data disk is located by
filesystem **UUID** (`<data-uuid>`), not mount path, since OMV mounts it at `/srv/dev-disk-by-uuid-<uuid>`.

- **Build stages run natively, not emulated.** Both Dockerfiles pin their SDK/npm build stage to
  `FROM --platform=$BUILDPLATFORM …` (the workstation's amd64) and target arm64 only for the final
  runtime image. The .NET publish is framework-dependent IL (`UseAppHost=false`) and the React build
  is static JS — both arch-neutral — so this skips slow QEMU emulation. **Don't drop the
  `--platform=$BUILDPLATFORM` pins** or the heavy build steps run under emulation again (minutes slower).
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
- CORS is `AllowAll` — flagged for tightening before any non-personal production use.
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
