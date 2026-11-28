# Video automation (*arr) stack in the Jellyfin LXC

Docker Compose in **pve CT 200** (`jellyfin`, 10.0.0.10), next to the native `jellyfin.service`. This stack is **not** managed by Argo CD.

- Spec: `docs/superpowers/specs/2026-11-28-arr-stack-design.md`
- Plan: `docs/superpowers/plans/2026-11-28-arr-stack.md`

| Service | URL (LAN only) | Notes |
|---|---|---|
| qBittorrent | http://10.0.0.10:8080 | Runs inside gluetun's network namespace and reaches the internet only through Proton WireGuard |
| Prowlarr | http://10.0.0.10:9696 | Indexers |
| Sonarr | http://10.0.0.10:8989 | Anime (`/data/anime`, tag `anime`) and TV (`/data/shows`) |
| Radarr | http://10.0.0.10:7878 | Movies (`/data/movies`) |
| Bazarr | http://10.0.0.10:6767 | Subtitles in ko/ja/en |
| Seerr | http://10.0.0.10:5055 | Request UI. Log in with your Jellyfin account. |
| FlareSolverr | (internal) | Solves Cloudflare challenges for Prowlarr indexers tagged `flaresolverr` |

Every container mounts host `/media` at `/data`, so imports are hardlinks. Downloads go to `/media/downloads/<category>`, which is outside every Jellyfin library. Containers run as `jellyfin` (uid 107, gid 110).

## Deploy and upgrade

```bash
scp lxc/jellyfin-arr/compose.yaml root@10.0.0.10:/opt/arr/compose.yaml
ssh root@10.0.0.10 'cd /opt/arr && docker compose pull && docker compose up -d'
```

Renovate opens bump PRs for `compose.yaml`. Merging a PR does **not** deploy it; run the commands above afterwards.

## LXC changes (made 2026-11-28; backup of the old conf at pve:`/root/200.conf.bak-pre-arr`)

- `memory: 8192` (was 4096)
- `/etc/pve/lxc/200.conf`:
  ```
  lxc.cgroup2.devices.allow: c 10:200 rwm
  lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
  ```
- Docker CE and the compose plugin come from the download.docker.com apt repo (noble).

## Secrets

- `/opt/arr/gluetun/wg0.conf` (0600) is the Proton WireGuard config for JP#153 with NAT-PMP on. IPv6 entries are stripped because gluetun refuses an IPv6 interface address when Docker has no IPv6. The untouched original is `wg0.conf.orig`. **Never commit either file.**
- App passwords are in Vaultwarden under "qBittorrent (arr)", "Sonarr (arr)" and so on. API keys are in `/opt/arr/config/<app>/config.xml`.

## VPN rotation (new server, expired key, or Proton changes)

1. Proton dashboard → Downloads → **WireGuard**. Choose platform **Router**, **NAT-PMP on**, and NetShield off, then click **Create** on a server with the P2P (⇄) icon.
2. Install the new config and restart:
   ```bash
   scp <file>.conf root@10.0.0.10:/opt/arr/gluetun/wg0.conf.orig
   ssh root@10.0.0.10 'cd /opt/arr/gluetun && install -m600 wg0.conf.orig wg0.conf && sed -i -E "s#^(Address|DNS|AllowedIPs) = ([^,]+),.*#\1 = \2#" wg0.conf && cd .. && docker compose up -d --force-recreate gluetun qbittorrent'
   ```
3. Run the checks below.

## Checks

```bash
# Egress must be a Proton IP, never the home IP
ssh root@10.0.0.10 'docker exec qbittorrent curl -s -m 10 https://ipinfo.io/ip'
# Kill switch: with the tunnel down, every request must time out (exit=28)
ssh root@10.0.0.10 'docker exec gluetun ip link set tun0 down; docker exec qbittorrent curl -s -o /dev/null -m 4 http://1.1.1.1; echo exit=$?; cd /opt/arr && docker compose restart gluetun && sleep 30 && docker compose up -d --force-recreate qbittorrent'
# The forwarded port must equal qBittorrent's listen port
ssh root@10.0.0.10 'docker logs gluetun 2>&1 | grep "port forwarded is" | tail -1; docker exec qbittorrent curl -s http://127.0.0.1:8080/api/v2/app/preferences | grep -o "\"listen_port\":[0-9]*"'
```

Run the kill-switch check right after taking the tunnel down. Gluetun's healthcheck brings the tunnel back up within about 10–20 s, and any request after that legitimately succeeds through the VPN.

## Gotcha: qBittorrent loses its network after a gluetun container restart

`network_mode: service:gluetun` binds qBittorrent to *that* gluetun container's network namespace. If the gluetun **container** restarts or is recreated, qBittorrent is left with no network. This is safe, because nothing leaks, but downloads stop. Fix it with:

```bash
ssh root@10.0.0.10 'cd /opt/arr && docker compose up -d --force-recreate qbittorrent'
```

Gluetun's own internal VPN reconnects, which happen during healthcheck restarts, do **not** cause this.

## qBittorrent settings (set via the API on 2026-11-28)

- Default save path is `/data/downloads`.
- Seeding stops at a ratio of 1.0 or after 7 days.
- UPnP and random port are off. The listen port is pushed by gluetun's `VPN_PORT_FORWARDING_UP_COMMAND`, which relies on "bypass auth for localhost" being on.

## Wiring (set via the APIs on 2026-11-28)

- **Sonarr**
  - Root folders: `/data/anime` and `/data/shows`.
  - Download clients point at qBittorrent at `gluetun:8080`:
    - `qBittorrent` uses category `tv` with priority 2 and no tags.
    - `qBittorrent-anime` uses category `anime` with priority 1 and tag `anime`. Sonarr treats untagged clients as eligible for every series, so the priority makes anime-tagged series land in `anime`.
  - Renaming is **off**, so existing folder names stay as they are. Hardlinks are on, and the minimum free space is 50 GB.
  - The 16 existing series were library-imported without moving files. Anime series have type Anime and tag `anime`.
  - Every series is monitored as "all", so an airing series such as Detective Conan gets new episodes through RSS. No backlog search was triggered.
  - TVDB folds Full Metal Panic's Fumoffu, The Second Raid and Invisible Victory into seasons of `Full Metal Panic!`. Only the base folder is managed, and the other folders are still visible in Jellyfin.
- **Radarr:** root `/data/movies`, qBittorrent category `movies`, hardlinks on, minimum free space 50 GB.
- **Prowlarr**
  - Indexers: Nyaa (anime), YTS (movies), EZTV (TV) and 1337x (TV and movies), all full-synced to Sonarr and Radarr.
  - EZTV and 1337x sit behind Cloudflare. They carry the tag `flaresolverr`, which routes them through the `flaresolverr` container (added 2026-11-28, internal only, no published port).
- **Bazarr**
  - Connected to Sonarr and Radarr.
  - Language profile `ko-ja-en` is the default for both series and movies.
  - Providers: Animetosho, plus OpenSubtitles.com and Jimaku once the API keys are added.
- **Jellyfin:** a new library "Movies" points at `/media/movies`. The existing libraries are Anime (`/media/anime`), Shows (`/media/shows`) and Study (`/media/english`), and `downloads/` is in none of them.

## Backup and restore

- **Schedule:** pve `/etc/cron.d/arr-config-backup` runs daily at 04:15. It tars CT 200's `/opt/arr/{config,gluetun,compose.yaml}` (excluding logs and MediaCover) to `/mnt/pve/backup-k12/arr/arr-config-<date>.tgz` and keeps 14 copies.
- **Permissions:** the archives contain the WireGuard private key, so the directory is 0700 and the files are 0600.
- **Restore:**
  ```bash
  ssh root@10.0.0.2 'pct exec 200 -- sh -c "cd /opt/arr && docker compose down"; cat /mnt/pve/backup-k12/arr/arr-config-<date>.tgz | pct exec 200 -- tar xzf - -C /opt/arr; pct exec 200 -- sh -c "cd /opt/arr && docker compose up -d"'
  ```
- **Media is not backed up.**

## Monitoring

- **Uptime Kuma:** HTTP monitors for Seerr, Sonarr, Radarr and qBittorrent, with the same notification as the other monitors.
- **Homepage:** the `Media` group has widgets for Seerr, Sonarr, Radarr and qBittorrent. Their keys are in `homepage-secrets` (`HOMEPAGE_VAR_SEERR_API_KEY`, `_SONARR_API_KEY`, `_RADARR_API_KEY`, `_QBIT_USER`, `_QBIT_PASSWORD`).

## Seerr

- Logs in with Jellyfin accounts. Jellyfin is reached at `http://10.0.0.10:8096`, and the external URL is set to `https://jellyfin.eli.kr` so "Play" links open there. The enabled libraries are Anime, Shows and Movies.
- Radarr is connected as `radarr:7878` with HD-1080p and `/data/movies`.
- Sonarr is connected as `sonarr:8989` with HD-1080p. Its default root is `/data/shows`, and anime requests go to `/data/anime` with tag `anime`.
- **Gotcha: TMDB timeouts.** Connecting to TMDB (CloudFront) takes about 1 s from this network. Node's happy-eyeballs gives each address only 250 ms, so every TMDB call failed with `ETIMEDOUT` and the UI showed "Series Not Found". `NODE_OPTIONS=--no-network-family-autoselection --dns-result-order=ipv4first` in `compose.yaml` fixes it.
