# Pastebin

A small, memory-lean pastebin for sharing text snippets and files. Built to run on a
**Raspberry Pi 3B behind CGNAT**, exposed publicly via **Tailscale Funnel** (no port-forwarding,
no TLS cert on the box). Metadata lives in embedded **SQLite**; large pastes and file blobs live
on the filesystem.

```
public ──HTTPS──▶ Tailscale Funnel ──HTTP──▶ nginx :80 ──▶ pastebin-api :8080
                  (terminates TLS)           (static SPA     (Nim, SQLite + blob store)
                                              + /api proxy)
```

- **`pastebin-api-nim/`** — Nim backend. The source of truth for all limits, quotas, and storage.
- **`pastebin-frontend/`** — React 18 SPA (`npm run build` → static `/build`).
- **`nginx/`** — serves the built SPA and reverse-proxies `/api/*` to the API. Plain HTTP on `:80`
  (TLS is terminated upstream by Funnel — do **not** add an HTTPS redirect).

## Run locally

```bash
cp .env.example .env      # defaults are fine for local use
docker compose up --build
```

Open <http://localhost>. To use a different host port:

```bash
PASTEBIN_HTTP_PORT=8080 docker compose up
```

## Deploy to a Raspberry Pi

Deploys are driven by [`Taskfile.yml`](Taskfile.yml) — run `task --list` for the menu. The flow is:
cross-build arm64 images on a fast workstation → push to a Docker registry **running on the Pi** →
the Pi pulls only the changed layers (never build on the Pi — it OOMs a 900 MB box).

**Prereqs.** Workstation: [`task`](https://taskfile.dev), Docker + `buildx`, and `sshpass` (or an
SSH key). Pi: Docker + Compose v2, a POSIX data dir (ext4/xfs/btrfs — **not** FAT32/exFAT), port 80
free. Tailscale admin console: MagicDNS, HTTPS certs, and Funnel enabled for the node.

1. **Configure** (both files are gitignored):
   ```bash
   cp .taskenv.example .taskenv   # PI_HOST, PI_PASS (or SSH key), PI_DATA_DIR or DATA_UUID
   cp .env.example .env           # TS_AUTHKEY, PUBLIC_BASE_URL, limits, etc.
   ```
2. **`task setup`** — one-time: start the registry on the Pi + a local insecure `buildx` builder.
3. **`task`** — build + push + deploy the stack (also copies your `.env` to the Pi).
4. **`task funnel`** — one-time: install Tailscale on the Pi and expose it publicly.

Check with `task ps` / `task logs`. The public URL is `https://<host>.<tailnet>.ts.net`.

## Configuration

All knobs are environment variables read by the API; [`.env.example`](.env.example) is the
source of truth (with defaults and descriptions). The main ones:

| Var | Default | Purpose |
|---|---|---|
| `MAX_REQUEST_BYTES` | 1 GB | Max bytes per upload/paste (keep in sync with nginx `client_max_body_size`) |
| `MAX_PASTE_BYTES` | 10 MB | Hard cap on a single paste |
| `MAX_STORAGE_BYTES_PER_IP` | 100 MB | Total stored bytes per client IP |
| `RATE_LIMIT_PER_IP_PER_MIN` | 120 | Requests/min per IP |
| `RATE_LIMIT_UPLOADS_PER_MIN` | 10 | Uploads & paste-creates/min per IP |
| `RATE_LIMIT_GLOBAL_CONCURRENCY` | 50 | Max concurrent requests before shedding load (503) |
| `NTFY_TOPIC` | _(unset)_ | ntfy.sh push on new paste/upload; unset ⇒ silent no-op |
| `ADMIN_TOKEN` | _(unset)_ | Enables the admin API via `X-Admin-Token`; unset ⇒ disabled |

**Admin API.** With `ADMIN_TOKEN` set, admin endpoints accept an `X-Admin-Token` header. A short
token is fine — failed attempts hit an escalating per-IP lockout plus a delay and constant-time
compare (see `pastebin-api-nim/src/adminguard.nim`).

> **Note:** CORS is currently `AllowAll` — tighten it before any shared/production use.

## More

- [`CLAUDE.md`](CLAUDE.md) — architecture, deploy internals, and RPi runtime notes.
- [`rpi-omv-setup.md`](rpi-omv-setup.md) — the physical Pi / OpenMediaVault runbook.
- [`docs/plans/`](docs/plans/) — design docs / roadmap.
