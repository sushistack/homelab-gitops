# Video automation (*arr stack) in the Jellyfin LXC: design

- **Date:** 2026-11-28
- **Status:** Draft, waiting for operator review
- **Scope:** pve LXC 200 (`jellyfin`, 10.0.0.10). This runs outside k3s and is not managed by GitOps.

## Goal

Automate anime, TV series and movies into the existing Jellyfin, with subtitles in Korean, Japanese and English. Torrent traffic must never leave from the home IP.

**Success criteria:**
1. A title requested in Jellyseerr shows up in the Jellyfin library without any manual steps, with subtitles.
2. When the VPN tunnel is down, qBittorrent cannot reach the internet. This is verified by a test, not assumed.
3. Imports use hardlinks, so a finished download costs no extra disk space.

## Decisions (operator answers, 2026-11-28)

| Topic | Decision |
|---|---|
| Content | Anime, TV series, movies, and automatic subtitles (ko/ja/en) |
| Download source | Torrent behind a VPN. Proton VPN Plus, 24 months, bought 2026-11-28. WireGuard with NAT-PMP port forwarding. |
| Placement | Docker Compose inside LXC 200. Same filesystem as `/media`, so hardlinks work. |

**Rejected:** running it on k3s. `/media` would have to be exported over NFS, hardlinks would not work across the mount, and the VPN sidecar setup is harder.

## Architecture

```
LXC 200 (Ubuntu 24.04, unprivileged)
├── jellyfin.service        (existing, native package, unchanged)
└── docker compose  /opt/arr/compose.yaml
    ├── gluetun       Proton WireGuard, NAT-PMP port forward, kill switch
    │   └── qbittorrent   network_mode: service:gluetun   (WebUI published via gluetun :8080)
    ├── prowlarr      :9696   indexers → Sonarr/Radarr
    ├── sonarr        :8989   anime (series type Anime) + TV
    ├── radarr        :7878   movies
    ├── bazarr        :6767   subtitles ko/ja/en
    └── jellyseerr    :5055   request UI, Jellyfin login
```

- **Images:** official or linuxserver.io images, pinned by tag. Renovate's built-in docker-compose manager picks up `lxc/jellyfin-arr/compose.yaml` and opens bump PRs. Deploying them stays manual (`docker compose pull && up -d` in the LXC), because Argo does not reach the LXC.
- **Only qBittorrent goes through the VPN.** Prowlarr, Sonarr, Radarr, Bazarr and Jellyseerr use the normal LAN route, because indexer APIs and metadata lookups don't need the VPN.
- **Port forwarding:** gluetun `VPN_PORT_FORWARDING=on` (provider protonvpn). Gluetun's port-update hook writes the forwarded port into qBittorrent's listen port, using the built-in `VPN_PORT_FORWARDING_UP_COMMAND` calling the qBittorrent WebUI API.
- **Kill switch:** gluetun's default firewall blocks all non-tunnel egress for containers that share its network namespace. LAN access to the WebUI is allowed with `FIREWALL_OUTBOUND_SUBNETS=10.0.0.0/24`.

## Storage layout

One filesystem (the LXC rootfs, 984G, 486G free on 2026-11-28). Every container mounts **`/media` as `/data`**, the same path everywhere, so hardlinks and path mapping need no translation.

```
/media/
├── downloads/{anime,tv,movies}   qBittorrent categories (excluded from Jellyfin libraries)
├── anime/     existing, Sonarr root folder (Anime)
├── shows/     existing, Sonarr root folder (TV)
├── movies/    new, Radarr root folder + new Jellyfin library
└── english/   untouched, not managed by any *arr
```

- **Ownership:** containers run as `PUID=107 / PGID=110` (the existing `jellyfin` user and group). New files are then readable by Jellyfin with no permission changes. `downloads/` and `movies/` are created as `jellyfin:jellyfin`. Existing `anime/` and `shows/` (root-owned, 755) get `chgrp -R jellyfin` plus `g+w` so Sonarr can rename files in them.
- **Existing titles:** Sonarr imports the existing anime and shows folders as existing series ("Library Import"). Files are not moved. Renaming stays **off**, so the current folder names don't change.
- **Config:** `/opt/arr/config/<app>/`, outside `/media`.

## LXC changes (on pve, via `pct`)

| Change | Why |
|---|---|
| memory 4096 → 8192 MB | The stack needs about 2–3 GB on top of Jellyfin's transcoding. The host has 31 GB free. |
| `lxc.cgroup2.devices.allow: c 10:200 rwm` and `lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file` | gluetun needs `/dev/net/tun` |
| `nesting=1,keyctl=1` | Already set. Docker can run in this unprivileged LXC. |

Docker comes from the docker.com apt repo (docker-ce plus the compose plugin).

## Policies

- **Quality:** Sonarr and Radarr use the default *HD-1080p* profile. Anime prefers releases from known groups via the `Anime` series type. Recyclarr is out of scope (see below).
- **Seeding:** qBittorrent stops at a ratio of 1.0 or 7 days of seeding, whichever comes first. Sonarr and Radarr then remove the torrent; the imported hardlink stays.
- **Disk guard:** Sonarr/Radarr minimum free space is 50 GB. qBittorrent's default save path is under `/data/downloads`.
- **Subtitles:** Bazarr languages are ko, ja, en. Providers: Jimaku (ja, anime), OpenSubtitles.com (ko/en), Animetosho (embedded anime subs). Free accounts. The operator provides the API keys.
- **Indexers:** Prowlarr starts with Nyaa (anime, public, no account). Other public indexers are added on request. Private trackers are out of scope.

## Access and auth

- **LAN only at first.** Each UI is reached at `http://10.0.0.10:<port>`, and every app has its own auth turned on (Forms login, or a WebUI password for qBittorrent).
- **Jellyseerr** logs in with Jellyfin accounts. Exposing it through Traefik and CF Access is a follow-up, not part of this work.
- **Homepage:** add Sonarr, Radarr, qBittorrent and Jellyseerr widgets under `Media`. Their API keys go into the homepage SealedSecret.

## Backup and monitoring

- **Backup:** a daily cron on the **pve host**: `pct exec 200 -- tar czf - -C /opt/arr config --exclude=logs --exclude=MediaCover > /mnt/pve/backup-k12/arr/arr-config-<date>.tgz`, keeping 14 copies. Running it on the host avoids bind-mounting NFS into an unprivileged LXC, where uid mapping and root squash get in the way. Media is not backed up, the same policy as today.
- **Monitoring:** Uptime Kuma HTTP monitors for Jellyseerr, Sonarr, Radarr and qBittorrent. A gluetun health check runs as a Docker healthcheck, and the `restart: unless-stopped` policy covers crashes.

## Repo footprint

- `lxc/jellyfin-arr/compose.yaml`: the source of truth, copied to `/opt/arr/` by hand. A `README.md` next to it records the LXC changes, first-run steps and the VPN rotation procedure.
- **Never committed:** `wg0.conf` and the Proton private key. They live only at `/opt/arr/gluetun/` (0600), and the repo's `.gitignore` already blocks `*.env`.

## Verification

1. **VPN egress:** `docker exec gluetun wget -qO- https://ipinfo.io/ip` returns a Proton IP, not the home IP.
2. **Kill switch:** take the tunnel interface down (`docker exec gluetun ip link set tun0 down`). Then `docker exec qbittorrent curl -m 10 https://ipinfo.io/ip` must time out. It must never return the home IP. Restart gluetun afterwards.
3. **Port forwarding:** gluetun logs a forwarded port, and qBittorrent's listen port matches it.
4. **End to end:** request one short anime and one movie in Jellyseerr. Check that the download, the hardlink import (same inode in `downloads/` and in the library), the Jellyfin library entry and the subtitles all appear.

## Out of scope (add when needed)

- Recyclarr: add when the default quality profiles produce bad picks.
- FlareSolverr: add when an indexer behind Cloudflare is needed.
- Unpackerr: add when releases arrive as rar.
- Exposing Jellyseerr to the internet.
- Usenet.
- Readarr and Lidarr.
