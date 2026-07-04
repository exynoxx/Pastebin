# Raspberry Pi / OpenMediaVault Setup Reference

> Collected `2026-06-28` via `ssh pi@<pi-ip>` — reference for deploying a web server on this box later.
> Sections below are that original point-in-time survey. **Read the current-state update first** — the
> pastebin stack has since been deployed and the storage/port picture changed.

## ⚠️ Current state (updated 2026-07-02)

The Pastebin stack is now **deployed and running** on this box, and several facts in the original
survey below are stale. What's true now (verified via SSH `2026-07-02`):

### Storage — a real btrfs data disk is now attached
| Device | Size | FS | Mount | Role |
|---|---|---|---|---|
| `mmcblk0p2` | 13.9 G | ext4 | `/` | SD-card rootfs (OS, OMV, Pi-hole data) |
| **`sdb`** | **30 G** | **btrfs** | `/srv/dev-disk-by-uuid-<data-uuid>` | **Live Pastebin data disk** |
| `sda1` | 7.5 G | ext4 | `/mnt/usb` | **stale** Pastebin copy + old image tarball (nothing live reads it) |

- **Live Pastebin data is on the new btrfs disk `<data-uuid>` (`/dev/sdb`)**, under `.../pastebin/`:
  `deploy/` (compose + `.env`), `db/pastebin.db` (SQLite + WAL), `blobs/`, and `registry/` (the on-Pi
  Docker registry storage). This disk is in `/etc/fstab` with `nofail` and mounts on boot.
- `sda1` was **reformatted FAT32 → ext4** since the survey (was the old "USB DISK" with 2019 files);
  it's now just a stale copy at `/mnt/usb`, mounted outside OMV.
- The btrfs disk `<omv-disk-uuid>` from the original note is **still missing** — OMV's own shares and Pi-hole
  still fall back to the SD card. That disk is unrelated to the Pastebin data disk `<data-uuid>`.

### Ports — OMV moved off :80
- **OMV web GUI was moved from :80 → :9000** (System → Workbench → Port) to free :80.
- **`pastebin-nginx` now owns host :80**; Tailscale Funnel proxies `https://<host>.<tailnet>.ts.net → :80`.
- Pi-hole still on 443 / 8080 / 53. The Pi's own Docker registry listens on **:5000** (loopback + LAN).

### Running containers (in addition to `pihole`)
| Name | Image | Restart | Notes |
|---|---|---|---|
| `pastebin-nginx` | `…/pastebin-nginx:rpi` | `unless-stopped` | serves SPA + proxies `/api` |
| `deploy-pastebin-api-1` | `…/pastebin-api:rpi` | `unless-stopped` | .NET 8 API, mem_limit 250m |
| `pastebin-registry` | `registry:2` | `always` | on-Pi registry, storage on the btrfs disk |

### Deploy & restart
- Deploy is via **`Taskfile.yml`** (build on workstation → push to the Pi's `:5000` registry → Pi pulls
  changed layers). See the repo `CLAUDE.md` "Deploy" section. (Not the OMV Compose plugin.)
- **Survives reboot on its own:** `docker` + `tailscaled` enabled; container restart policies set;
  `docker.service` has `After=…<data-uuid>.mount` so it waits for the data disk. See `CLAUDE.md`
  "RPi runtime & restart survival" for the full checklist and the `nofail` caveat.

---


## Connection

| | |
|---|---|
| Host / IP | `<pi-ip>` (static-ish, DHCP lease, metric 100 on `eth0`) |
| SSH | `ssh pi@<pi-ip>` — password `<pi-password>` |
| User | `pi` (uid 1000), **passwordless sudo** (`sudo -n` works) |
| Hostname | `raspberrypi` |
| mDNS | avahi running → likely reachable as `raspberrypi.local` |
| Groups | `sudo`, `docker`, `openmediavault-admin`, `sambashare`, gpio/i2c/spi, etc. |

`pi` is in the `docker` group → can run `docker` / `docker compose` without sudo.

## Hardware

| | |
|---|---|
| Model | **Raspberry Pi 3 Model B Rev 1.2** |
| Serial | `<serial>` |
| CPU | Cortex-A53, 4 cores (aarch64 / arm64) |
| RAM | **906 MB total** (~107 MB free, ~577 MB available) — tight |
| Swap | 512 MB (dphys-swapfile) |
| Temp | 49.4 °C, throttled `0x0` (healthy) |

> ⚠️ Only ~900 MB RAM on a Pi 3B. Keep web stack lightweight; watch memory if running alongside Pi-hole.

## OS / Kernel

| | |
|---|---|
| OS | **Debian GNU/Linux 12 (bookworm)** |
| Kernel | `6.12.34+rpt-rpi-v8` aarch64 |
| Arch | arm64 — pull `linux/arm64` Docker images |

## Storage ⚠️ IMPORTANT

| Device | Size | FS | Mount | Notes |
|---|---|---|---|---|
| `mmcblk0p2` | 13.9 G | ext4 | `/` | **rootfs — 3.5 G used, 9.6 G free** |
| `mmcblk0p1` | 512 M | vfat | `/boot/firmware` | bootfs |
| `sda1` | 7.5 G | vfat (FAT32) | *(unmounted)* | USB stick `USB DISK`, **828 M used / 6.7 G free** — see below |

### USB stick (`/dev/sda1`)
- Generic **"USB Disk 2.0"** (`lsusb` ID `ffff:5678`), 7.5 G, **FAT32**, label `USB DISK`, no UUID/serial reported.
- **Not referenced in OMV config** — it's just plugged in, not mounted, not a configured OMV disk/share.
- Currently **828 M used, 6.7 G free**. Contents are old personal files from 2019 (a `.mkv` video + several Python `.pkl` pickle files — map/graph data like `dk_roads.pkl`, `allLand.pkl`), plus a `System Volume Information` folder.
- To use it for a web server (e.g. app data/static files): add it as a filesystem in OMV (Storage → File Systems → mount) or fstab. **FAT32 caveat:** no Unix permissions/symlinks, 4 GB max file size — fine for static assets, not ideal for databases/containers. Reformat to ext4/btrfs if you want it as real app storage.

**Key gotcha:** OMV's data disk — a **btrfs** filesystem (`uuid <omv-disk-uuid>`) referenced in fstab/OMV config at
`/srv/dev-disk-by-uuid-<omv-disk-uuid>` — is **NOT currently present/mounted**.
- `findmnt` confirms that path is *not* a mountpoint; `btrfs filesystem show` finds nothing; `lsblk` shows no btrfs device.
- The fstab entry uses `nofail`, so boot succeeds without it.
- **Consequence:** the OMV shared folders (`shared`, `internal`) and **all Pi-hole data currently live on the SD card rootfs**, not on a separate disk. Any "shared folder" you point a web app at right now is really SD-card storage. If that btrfs disk is supposed to be attached, it's missing — verify before storing anything important.

## Network

- `eth0`: **<pi-ip>/24**, gateway `192.168.0.1` (DHCP, route metric 100). **Primary link.**
- `wlan0`: **WiFi failover** — normally DOWN, comes up automatically only when `eth0` loses its
  carrier (cable unplugged / switch dead), then drops back when the cable returns. SSID
  `<wifi-ssid>`; on WiFi it gets `192.168.0.32/24` (same LAN, so Tailscale rides it seamlessly).
  See **WiFi failover** below.
- Docker bridges: `docker0` 172.17.0.1/16 (down), `br-93ad86aecb0f` 172.18.0.1/16 (Pi-hole's `pi-hole_default` net).

### WiFi failover (wired-primary, wireless hot-spare)

The Pi prefers ethernet and falls back to WiFi only when the cable is unavailable. Networking is
**netplan → systemd-networkd** (NetworkManager is present but `managed=false`, so it only owns
docker/tailscale/bridge interfaces). Pieces, all persistent across reboot:

- **`/etc/netplan/90-wifi-failover.yaml`** — hand-added override (high number so OMV's rewrites of
  `30-openmediavault-wlan0.yaml`, which holds the SSID/password, don't clobber it). Netplan
  deep-merges it onto the OMV wlan0 stanza, adding `activation-mode: manual` (networkd configures
  wlan0 but never brings it up itself), `optional: true` (boot's `wait-online` doesn't block on it),
  and `dhcp4-overrides.route-metric: 700` (wired's metric-100 route always wins if both are up).
- **`wifi-regdomain.service`** — oneshot that runs `rfkill unblock wifi` + `iw reg set DK` every
  boot. ⚠️ The Pi's onboard radio is **rfkill soft-blocked until a WiFi country is set** — this is
  why wlan0 wouldn't connect before. `iw reg set` is not persistent, hence the boot-time service.
- **`wifi-failover.service`** → **`/usr/local/sbin/wifi-failover.sh`** — owns wlan0 up/down. Watches
  `eth0` link events via `ip monitor` (plus a 15s safety re-check); on carrier loss it
  `networkctl up wlan0`, on carrier return `networkctl down wlan0`. Failover is near-instant
  (verified 2026-07-02: `eth0` down → wlan0 routable with internet in a few seconds → `eth0` back →
  wlan0 down).

## Listening ports (what's already taken)

| Port | Proto | Service | Notes |
|---|---|---|---|
| **80** | tcp | **nginx → OMV web GUI** | `listen 80 default_server`, root `/var/www/openmediavault`, PHP 8.2-FPM |
| **443** | tcp | docker-proxy → **Pi-hole** | container |
| **8080** | tcp | docker-proxy → **Pi-hole web UI** (container :80) | |
| **53** | tcp/udp | docker-proxy → **Pi-hole DNS** | |
| 445 / 139 | tcp | Samba (`smbd`) | |
| 5355 | tcp | systemd-resolved (LLMNR) | |
| 5357 | tcp | `wsdd` (WS-Discovery, Samba) | bound per-interface |
| 4999 | tcp | `omv_cterm.py` (OMV container terminal) | |
| 22 | tcp | sshd | |

> 🚫 **Ports 80, 443, 8080, 53 are all in use.** For a new web server pick a free port (e.g. `3000`, `8000`, `8081`, `8443`) **or** reconfigure OMV's GUI off port 80 first.

## Services

**Web / OMV stack (running):** `nginx`, `php8.2-fpm`, `openmediavault-engined`, `omv_cterm`, `monit`, `rrdcached`, `collectd`.

**Containers:** `docker` + `containerd` (enabled, running).

**File sharing:** `smbd` running; `samba-ad-dc` enabled. `wsdd-server` for Windows discovery.

**System:** NetworkManager (active) + systemd-networkd + systemd-resolved all present, chrony (NTP), cron, anacron, unattended-upgrades, bluetooth, ModemManager, avahi.

## Docker

| | |
|---|---|
| Docker | **28.4.0** |
| Compose | **v2.39.2** (`docker compose` plugin) |

### Running containers
| Name | Image | Ports | Restart |
|---|---|---|---|
| `pihole` | `pihole/pihole:latest` | `53→53/tcp+udp`, `443→443`, `8080→80`, (67/123/udp) | `unless-stopped` |

- Pi-hole data bind-mount: `/srv/dev-disk-by-uuid-<omv-disk-uuid>/internal/pi-hole/etc-pihole → /etc/pihole` (on SD card, see storage note).
- Pi-hole env: `TZ=Europe/London`, `FTLCONF_dns_listeningMode=all`, web/API passwords set (`WEBPASSWORD`, `FTLCONF_webserver_api_password`).
- Networks: `bridge`, `host`, `none`, `pi-hole_default` (172.18.0.0/16).

> The Pi-hole compose file itself wasn't found on disk under the data dir — it's managed by the **OMV Compose plugin** (see below). Edit/redeploy stacks through the OMV web UI, not by hand.

## OpenMediaVault

| | |
|---|---|
| Version | **openmediavault 7.7.15-2** (OMV 7 "Sandworm", on Debian 12) |
| Web GUI | nginx on **port 80**, no SSL configured (default port/sslport unset in config) |
| GUI root | `/var/www/openmediavault` |
| Config | `/etc/openmediavault/config.xml` (read with `sudo xmlstarlet sel`) |

**Installed OMV plugins:** `compose 7.6.13`, `k8s 7.4.11-2`, `cterm 7.8.7`, `apt`, `omvextrasorg`, `resetperms`, `sharerootfs`.

> `openmediavault-compose` + `openmediavault-k8s` are installed → the intended way to deploy containerized apps (incl. a web server) is **via the OMV Compose plugin in the web UI**, which is how Pi-hole is managed.

### Shared folders
| Name | Rel. path | Backing |
|---|---|---|
| `internal` | `internal/` | btrfs data disk (currently on SD rootfs — see storage note) |
| `shared` | `shared/` | same |

- Compose plugin data shared-folder ref: `<omv-sharedfolder-uuid>` → maps to `internal`.

### Samba shares
| Share | Path | Access |
|---|---|---|
| `shared` | `/srv/dev-disk-by-uuid-<omv-disk-uuid>/shared/` | read-write, guest = no, enabled |

`samba-ad-dc.service` is enabled but the active daemon is plain `smbd` serving the `[shared]` share.

## Notes for deploying a web server later

1. **Free ports only.** 80 (OMV), 443/8080/53 (Pi-hole) are taken. Use e.g. `8081`/`3000`/`8000`, or move the OMV GUI to another port to reclaim 80/443.
2. **Deploy via OMV Compose plugin** (web UI → Services → Compose) to stay consistent with how Pi-hole runs and survive reboots — rather than ad-hoc `docker run`.
3. **arm64 / linux/arm64 images** required.
4. **Low RAM (900 MB)** shared with Pi-hole — favor nginx/Caddy/static or a small app; avoid heavy stacks.
5. **Reverse proxy option:** since OMV owns nginx on :80, consider adding a containerized reverse proxy (Caddy/Traefik/nginx-proxy) on a free port, or carefully add a vhost — but don't fight OMV's managed nginx config.
6. **Storage caveat:** confirm/attach the intended btrfs data disk before putting app data on a "shared folder" — right now it's all on the SD card.
7. Passwordless sudo + docker group on `pi` makes automated deploys easy over SSH.

## Services that can be disabled to free resources

Context: headless Pi 3B on ethernet, role = OMV NAS + Pi-hole + future web server. Memory figures are live RSS at time of audit (900 MB total RAM).

### Safe — OS-level (`systemctl disable`, not OMV-managed)
| Service | ~RAM | Why irrelevant |
|---|---|---|
| `ModemManager` | 10 MB | cellular/dial-up modem mgr — no modem |
| `wpa_supplicant` + `netplan-wpa-wlan0` | 8 MB | WiFi — on `eth0`, `wlan0` DOWN (only if staying wired) |
| `bluetooth` + `hciuart` | 3 MB | no Bluetooth use, headless |
| `triggerhappy` | 1 MB | GPIO/keyboard hotkey daemon — none |
| `rpi-display-backlight` | 0 | RPi touchscreen — none attached |

```bash
sudo systemctl disable --now ModemManager triggerhappy bluetooth hciuart rpi-display-backlight
sudo systemctl mask bluetooth
# WiFi only if permanently wired (no WiFi fallback console):
sudo systemctl disable --now wpa_supplicant netplan-wpa-wlan0
```

### Optional — OMV-managed (toggle in OMV web UI / remove plugin, NOT systemctl — OMV reverts manual changes)
| Service | ~RAM | Trade-off |
|---|---|---|
| `omv_cterm` (port 4999) | **39 MB** | OMV web container-terminal plugin (`openmediavault-cterm`). Remove plugin if unused. |
| `collectd` + `rrdcached` | 25 MB | OMV dashboard perf graphs. Disable via *System → Monitoring*. |
| `wsdd-server` | 20–27 MB | Windows "Network" auto-discovery. Disable in Samba settings if connecting by IP/host. |
| `samba-ad-dc` | 0 (inactive) | Samba AD domain controller, enabled but unused → `sudo systemctl mask samba-ad-dc`. |

### Keep (core)
`nginx`, `php8.2-fpm`, `openmediavault-engined`, `docker`, `containerd`, `smbd`, `monit`, `ssh`, `chrony`, `systemd-resolved`, `NetworkManager`, `unattended-upgrades`.

> Potential: ~22 MB risk-free (OS group) up to ~90 MB if cterm + monitoring + wsdd are also dropped.

## Handy commands

```bash
# connect
sshpass -p '<pi-password>' ssh -o StrictHostKeyChecking=no pi@<pi-ip>

# OMV config dump
sudo xmlstarlet sel -t -c "//config/services/compose" -n /etc/openmediavault/config.xml

# what's listening
sudo ss -tlnp

# docker
docker ps -a
docker compose version
```
