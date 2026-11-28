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
