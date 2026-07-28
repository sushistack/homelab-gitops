# Runbook: memos

## What it does

Self-hosted quick-notes app (usememos/memos) at the public host `${SECRET:DOMAIN_MEMOS}`. Single
Go binary, SQLite-backed (`/var/opt/memos/memos_prod.db` on the `memos-data` PVC). Own login —
private-mode by default (sign-in required; first registrant becomes owner). Public, own-auth tier
— same class as ntfy/karakeep/miniflux, NOT CF Access.

## Health check (exact command → expected output)

```sh
curl -fsS -o /dev/null -w '%{http_code}\n' https://${SECRET:DOMAIN_MEMOS}/     # -> 200
kubectl -n memos get pods                                                     # -> Running/1/1 Ready
kubectl -n argocd get applications.argoproj.io memos \
  -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'           # -> Synced/Healthy
```

## If DOWN do this (in order)

1. **Pod not Ready?** `kubectl -n memos describe pod -l app.kubernetes.io/name=memos`. `memos-data`
   is `local-path-retain` (hostPath-backed, node-pinned via the PV's nodeAffinity from first bind)
   — NOT network-attached storage. If the pod is `Pending` because its node is down, it stays
   `Pending` until that exact node returns; it will NOT reschedule elsewhere. `Recreate` strategy
   only guarantees no *second* pod exists concurrently, it does not add mobility.
2. **Public host 5xx but pod Healthy?** Check the `memos-tls` cert (`kubectl -n memos get certificate
   memos-tls` → Ready) and that the IngressRoute's `external-dns` CNAME resolves (`dig
   ${SECRET:DOMAIN_MEMOS}` → the tunnel target).
3. **`memos-backup-r2` Secret missing?** The SealedSecret failed to decrypt — see Common failures #2.

## Common failures

1. **Two pods / corrupt SQLite.** Must never happen — the Deployment is `strategy: Recreate` (old
   pod torn down before the new one starts). If you ever see two, RollingUpdate crept back in.
2. **SealedSecret won't decrypt** (`memos-backup-r2` Secret never appears). Sealed to `name+namespace`
   — a rename breaks it. Re-seal against the live controller:
   `kubectl create secret generic memos-backup-r2 -n memos --dry-run=client -o yaml --from-literal=... | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml`.
3. **Backup CronJob fails on `apk add`.** Installs sqlite/rclone at runtime over 80/443 to the Alpine
   CDN. If a future network-baseline tightens egress, allow the CDN + R2, or bake a pinned image.

## Backup/restore commands

**Backup** — `memos-backup` CronJob, every 6h, online `sqlite3 .backup` (no quiesce) →
`r2:homelab-k3s-services-backup/memos/`, 72h retention:

```sh
kubectl -n memos create job --from=cronjob/memos-backup memos-backup-manual   # manual one-off
```

**Restore** — fetch the archive from R2 and copy it onto the PVC via the scratch ingest Job
(`_restore/ingest-job.yaml`, mirrors ntfy's cutover pattern). Suspend autosync first — otherwise
ArgoCD's `selfHeal` reverts `--replicas=0` back to 1 mid-restore and both pods race for the RWO PVC:

```sh
rclone copy r2:homelab-k3s-services-backup/memos/memos-<ts>.tar.gz /tmp/
tar -C /tmp -xzf /tmp/memos-<ts>.tar.gz     # -> /tmp/memos_prod.db

kubectl -n argocd patch app memos --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n memos scale deploy/memos --replicas=0
kubectl apply -f workloads/memos/_restore/ingest-job.yaml
pod=$(kubectl -n memos get pod -l job-name=memos-ingest -o name | head -1)
kubectl -n memos cp /tmp/memos_prod.db "${pod#pod/}:/data/memos_prod.db"
kubectl -n memos delete -f workloads/memos/_restore/ingest-job.yaml

kubectl -n memos scale deploy/memos --replicas=1
kubectl -n argocd patch app memos --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

## Escalation / depends-on

- **Depends on:** `local-path-retain` PVC (`memos-data`), cert-manager + `letsencrypt-prod`
  (`memos-tls`), the SealedSecrets controller (decrypts `memos-backup-r2`), the cloudflared tunnel
  (public route for `${SECRET:DOMAIN_MEMOS}`).
- **Alerting:** none dedicated yet — covered only by the general ArgoCD Application health signal.
