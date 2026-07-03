# Runbook: slskd (Soulseek FLAC download source)

> Single headless Soulseek daemon on k3s-cp-1, sharing the node-local music library `/mnt/music`
> (dedicated 200G disk, scsi3). slskd downloads lossless releases into `/mnt/music/.incoming`;
> music-curator drives it (track-level search/download for weekly_discovery) via the in-cluster API.
> Navidrome serves the same `/mnt/music`, so new music appears with no copy. UI (5030) is INTERNAL —
> behind CF Access (Google SSO). (Lidarr + soularr were removed; music-curator does track-level directly.)

## Health check (exact command → expected output)

```
kubectl -n slskd get pods           # expected: slskd 1/1 Running
kubectl -n slskd exec deploy/slskd -- wget -qO- localhost:5030/ >/dev/null && echo OK  # web up (probes use / too)
```

slskd Soulseek login: open the slskd UI → it shows "Connected" once the credentials are valid.

## If DOWN do this (in order)

1. **Pod Pending / unschedulable** → the node-local PV pins slskd to `k3s-cp-1`. Confirm the node is
   Ready and the disk is mounted: `ssh root@10.0.0.2` → on k3s-cp-1 `mountpoint /mnt/music && df -h /mnt/music`.
2. **Pod stuck `ContainerCreating` ("secret not found")** → the `slskd-soulseek` SealedSecret didn't
   decrypt (target Secret never created → envFrom can't resolve). Reseal with real values (below).
3. **slskd connected but login fails** → wrong Soulseek creds. Reseal `slskd-soulseek`, then
   `kubectl -n slskd rollout restart deploy/slskd` (subPath mounts do NOT live-update on reseal).
4. **Downloads not landing** → check `/mnt/music/.incoming` ownership is uid 1000
   (`ssh root@10.0.0.2` → `ls -ln /mnt/music/.incoming`). `.incoming`/`.incomplete` are dot-prefixed so
   Navidrome's scanner skips partial downloads.

## Common failures

- **Disk full** — `/mnt/music` is a dedicated disk (scsi3), separate from manga. Grow online:
  `ssh root@10.0.0.2` → `qm resize 101 scsi3 +50G` then on k3s-cp-1 `resize2fs /dev/sdX` (whole-disk ext4).
- **Leeching** — `shares` is empty (download-only); some Soulseek peers throttle non-sharers. Add a
  shared dir in `configmap.yaml` if download speeds suffer.

## Ops commands

**Disk prep (once, before first deploy)** — `ssh root@10.0.0.2`, then on k3s-cp-1:
```
mkdir -p /mnt/music/.incoming /mnt/music/.incomplete
chown -R 1000:1000 /mnt/music      # match slskd uid 1000
```

**Reseal slskd creds** — see the header comment in `sealedsecret-slskd.yaml` for the exact
`kubectl create secret … | kubeseal` command (sealed to `slskd-soulseek/slskd`). After reseal+sync:
`kubectl -n slskd rollout restart deploy/slskd` (slskd.yml is a subPath mount, no live-update).

Config (`slskd.db`) state is regenerable — the config PVC is a fresh `local-path-retain` claim, not
backed up. Music files are re-acquirable (re-download), so no R2 backup either.

## Escalation / depends-on

- **Storage:** node-local PV → k3s-cp-1 `/mnt/music` dedicated disk (scsi3, separate from komga manga).
- **Exposure:** Traefik IngressRoute + cert-manager (letsencrypt-prod, DNS-01) + CF Access (Google SSO)
  + the shared cloudflared tunnel (`761ca633…cfargotunnel.com`). Host: `${SECRET:DOMAIN_SLSKD}`
  (register in `internal/tokens.example.env`).
- **Secrets:** sealed-secrets controller (kubeseal). **Downstream:** Navidrome (serves the library),
  music-curator (drives slskd API). **External:** a valid Soulseek account. No inbound port-forward.
