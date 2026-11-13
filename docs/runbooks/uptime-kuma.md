# Runbook: uptime-kuma

> HTTP prober for the homelab (ns `uptime-kuma`), alerts via ntfy. SQLite (`kuma.db`) on a
> `local-path-retain` PVC → **pinned to one node** (today `k3s-cp-2`, moved from cp-1 on 2026-11-13). Manifests:
> [`workloads/uptime-kuma/`](../../workloads/uptime-kuma/). Kuma itself is watched out-of-band by
> healthchecks.io (see [ops-alerts.md](ops-alerts.md) "Self-monitoring").

## Backup

`uptime-kuma-backup` CronJob, `50 */6 * * *` KST: online `sqlite3 .backup` →
`r2:homelab-k3s-services-backup/uptime-kuma/uptime-kuma-<UTC ts>.tar.gz` (only `kuma.db`; uploads
are not backed up), 72h retention. Credential: `uptime-kuma-backup-r2` Secret (same ns).

**RPO = up to 6h.** Monitors/notifications edited in the UI after the last backup are lost on
restore. After a meaningful config change, take one on demand:

```
kubectl create job -n uptime-kuma --from=cronjob/uptime-kuma-backup uptime-kuma-backup-manual
kubectl wait -n uptime-kuma job/uptime-kuma-backup-manual --for=condition=complete --timeout=200s
kubectl delete job -n uptime-kuma uptime-kuma-backup-manual
```

## Restore

Tool: [`_restore/restore-job.yaml`](../../workloads/uptime-kuma/_restore/restore-job.yaml) (not
Argo-managed). Pulls the newest R2 archive (or `BACKUP_FILE`), runs `integrity_check`, drops stale
`-wal/-shm`, copies `kuma.db` into the PVC. Refuses to overwrite an existing `kuma.db` unless
`FORCE=1`. Drill-measured: restore Job ~16s, kuma Ready ~5s after start.

The workloads ApplicationSet ignores Deployment `/spec/replicas` → `kubectl scale` is NOT reverted
by selfHeal; no need to disable autosync.

### A. DB corrupt / bad config, node healthy (same PVC)

```
kubectl -n uptime-kuma scale deploy/uptime-kuma --replicas=0
# FORCE=1 overwrites the existing kuma.db (set BACKUP_FILE the same way to pick an older archive):
sed 's/{name: FORCE, value: "0"}/{name: FORCE, value: "1"}/' \
  workloads/uptime-kuma/_restore/restore-job.yaml | kubectl apply -f -
kubectl -n uptime-kuma logs -f job/uptime-kuma-restore      # → "restored: monitors=N — <names>"
kubectl -n uptime-kuma delete job uptime-kuma-restore
kubectl -n uptime-kuma scale deploy/uptime-kuma --replicas=1
```

### B. Pinned node dead (cp-1 lost) — restore onto another node

Only if the node is not coming back soon: its local volume holds data **newer** than R2. The old PV
is `Retain`, so nothing below destroys it.

1. **PR: delete the `volumeName:` line** in `workloads/uptime-kuma/pvc.yaml` and merge. Otherwise a
   recreated PVC tries to bind the dead node's PV and stays Pending.
2. Free the claim:
   ```
   kubectl -n uptime-kuma scale deploy/uptime-kuma --replicas=0
   kubectl -n uptime-kuma delete pod -l app.kubernetes.io/name=uptime-kuma --force --grace-period=0
   # COMPLETED backup-Job pods still reference the PVC and pvc-protection blocks deletion until they're gone
   # (2026-11-13 live run: kuma stalled 9 min here). Delete those Jobs first:
   kubectl -n uptime-kuma get pods -o json | jq -r '.items[]|select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName=="uptime-kuma-data"))|.metadata.ownerReferences[0].name' \
     | sort -u | xargs -r kubectl -n uptime-kuma delete job
   kubectl -n uptime-kuma delete pvc uptime-kuma-data
   ```
   Argo recreates the PVC (no volumeName) → `Pending` (WaitForFirstConsumer) — expected.
   If it doesn't reappear within ~3 min: `argocd app sync uptime-kuma`.
3. Restore (the Job is the first consumer → the volume is provisioned on the node it lands on):
   ```
   kubectl apply -f workloads/uptime-kuma/_restore/restore-job.yaml
   kubectl -n uptime-kuma logs -f job/uptime-kuma-restore
   kubectl -n uptime-kuma delete -f workloads/uptime-kuma/_restore/restore-job.yaml
   kubectl -n uptime-kuma scale deploy/uptime-kuma --replicas=1   # follows the PV to the same node
   ```
4. Verify: UI loads + monitors present; healthchecks `homelab uptime kuma` back to green within 5 min.
5. Later: optionally re-pin the new `volumeName` via PR (convention from 69aa8ba); when cp-1 returns,
   delete its orphaned Released PV once you're sure you don't need it.

## Non-destructive drill (done 2026-11-13, PASS)

Restore into a scratch namespace on a non-cp-1 node; prod untouched:

1. `kubectl create ns kuma-restore-drill`; copy `uptime-kuma-backup-r2` into it; create a
   `uptime-kuma-data` PVC there (`storageClassName: local-path`).
2. Apply `restore-job.yaml` with `namespace` sed'ed to the drill ns (+ a `NotIn k3s-cp-1` nodeAffinity).
3. Boot a kuma pod on that PVC with an init step `update monitor set active=0;` — **mandatory**:
   an active copy would double-notify and ping healthchecks, masking a real kuma outage.
4. Check `/api/entry-page` responds and `select count(*) from monitor` matches prod; `kubectl delete ns kuma-restore-drill`.

Finding from the drill: the newest backup was 5h old and missed a monitor added that day → the RPO
note above.

## Live run of B (2026-11-13, PASS)

Executed procedure B in production (cp-1 simulated lost via `NotIn k3s-cp-1` on the restore Job):
kuma moved cp-1 → **cp-2**, 16/16 monitors restored. Downtime 618s — 9 min of it stuck on PVC
deletion because completed backup-Job pods held the claim (step 2 now deletes them first; ntfy's run
with that step: 18s). Old PV `pvc-5c7c6b4c-…` left `Released` on cp-1 as a fallback.
