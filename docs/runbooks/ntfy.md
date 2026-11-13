# Runbook: ntfy

> One-way push notification hub, migrated to k3s via the stateful-cutover machine (Story 4.1 —
> the FIRST stateful cutover). **DB-class** (SQLite `auth.db` durable + `cache.db` transient).
> Cutover procedure + rollback: [stateful-cutover.md](stateful-cutover.md).

## What it does

Push hub: **Kuma + n8n → ntfy → mobile apps** (background push relayed via the `ntfy.sh`
upstream, FCM/APNs). `binwiederhier/ntfy serve`, port 80, behind Traefik on
`${SECRET:DOMAIN_NTFY}`. Auth is `deny-all` by default; users/tokens/ACLs live in
`auth.db`, cached messages in `cache.db` (12h TTL). Publishers (Kuma/n8n) authenticate with a
client-side token — that is *their* config, not ntfy's (ntfy itself holds no app secret).

## Health check (exact command → expected output)

```
curl -fsS https://${SECRET:DOMAIN_NTFY}/v1/health      # → {"healthy":true}
```

In-cluster / ArgoCD: `kubectl get pods -n ntfy` → pod `Running`/`Ready`;
`argocd app get ntfy` → `Synced` + `Healthy`;
`kubectl get deploy ntfy -n ntfy -o jsonpath='{.spec.strategy.type}'` → `Recreate`.

## If DOWN do this (in order)

1. **Pod** — `kubectl get pods -n ntfy`; if not `Running`:
   `kubectl describe pod -n ntfy -l app.kubernetes.io/name=ntfy` (watch for `Multi-Attach`
   on the PVC — see Common failures).
2. **Logs** — `kubectl logs -n ntfy deploy/ntfy --tail=100`.
3. **PVC mount** — `kubectl get pvc -n ntfy ntfy-data` → `Bound`;
   `kubectl exec -n ntfy deploy/ntfy -- ls -l /var/cache/ntfy` shows `auth.db` + `cache.db`.
4. **Config** — `kubectl exec -n ntfy deploy/ntfy -- cat /etc/ntfy/server.yml`; if the host/base-url
   is wrong, the render token (`DOMAIN_NTFY`) was not substituted.
5. **Public route** — confirm the `${SECRET:DOMAIN_NTFY}` cloudflared route points at Traefik
   (`https://<node>:443`, `originServerName=${SECRET:DOMAIN_NTFY}`). k3s is the sole production path
   (Compose retired 2026-06-19) — recover via R2 restore / `git revert` + ArgoCD sync, not a flip-back.
6. **Egress** — if a NetworkPolicy baseline ever lands, confirm ns `ntfy` is allowed DNS :53 +
   egress to `ntfy.sh`; without it background push silently dies while the pod stays `Healthy`.
7. **Restart / revert** — `kubectl rollout restart deploy/ntfy -n ntfy`; the real fix for bad config
   is `git revert` (GitOps; ArgoCD selfHeal re-converges manual drift).

## Common failures

- **`Multi-Attach error` on `ntfy-data`** — the RWO Longhorn volume is held by one node and the
  backup CronJob (or a stray pod) landed elsewhere. The CronJob uses `podAffinity` to co-locate
  onto the ntfy pod's node; if it still trips, the pod was rescheduled — confirm both are on the
  same node (`kubectl get pod -n ntfy -o wide`). (Reconciliation 1 / stateful-cutover.md.)
- **Upstream `ntfy.sh` egress blocked** — mobile apps get no notification while backgrounded,
  though direct/foreground delivery works and the pod is `Healthy`. Allow egress to `ntfy.sh`.
- **`auth-default-access: deny-all` lockout** — a publish/subscribe with no/invalid token gets 403.
  This is by design; fix the publisher's token (`auth.db` ACL), not the server.
- **Stale image pin / bad digest** — `ImagePullBackOff`; re-pin via PR.

## Backup/restore commands

**DB-class — real backup, NOT N/A.** A `ntfy-backup` CronJob (ns `ntfy`, ≤6h) takes an online
`sqlite3 .backup` of both DBs and uploads to `r2:homelab-k3s-services-backup/ntfy/` (replaces the Compose
offen sidecar). Credential: the per-namespace `ntfy-backup-r2` SealedSecret.

**Run a backup on demand:**
```
kubectl create job -n ntfy --from=cronjob/ntfy-backup ntfy-backup-manual
kubectl logs -n ntfy job/ntfy-backup-manual -f
# verify it landed:
rclone lsl r2:homelab-k3s-services-backup/ntfy/ | tail
```

**RPO = up to 6h** (users/tokens/ACL changed since the last backup are lost). After `ntfy user` /
`ntfy access` / `ntfy token` changes, take a backup on demand (above).

**Restore** — tool: [`_restore/restore-job.yaml`](../../workloads/ntfy/_restore/restore-job.yaml)
(not Argo-managed). Pulls the newest R2 archive (or `BACKUP_FILE`), `integrity_check`s both DBs,
drops stale `-wal/-shm`, copies `auth.db` (+ `cache.db`) into the PVC. Refuses to overwrite an
existing `auth.db` unless `FORCE=1`. Drill-measured: restore ~9s, ntfy Ready ~1s after start.

The workloads ApplicationSet ignores Deployment `/spec/replicas` → `kubectl scale` is NOT reverted by
selfHeal; no need to disable autosync.

*A. DB corrupt / bad ACL change, node healthy (same PVC):*
```
kubectl -n ntfy scale deploy/ntfy --replicas=0
sed 's/{name: FORCE, value: "0"}/{name: FORCE, value: "1"}/' \
  workloads/ntfy/_restore/restore-job.yaml | kubectl apply -f -
kubectl -n ntfy logs -f job/ntfy-restore          # → "restored: users=N tokens=N acl=N"
kubectl -n ntfy delete job ntfy-restore
kubectl -n ntfy scale deploy/ntfy --replicas=1
```

*B. Pinned node dead (`ntfy-data` PV is local-path on `k3s-cp-1`) — restore onto another node.*
Only if the node isn't coming back soon (its volume is newer than R2; the old PV is `Retain`, untouched):

1. **PR: delete the `volumeName:` line** in `workloads/ntfy/pvc.yaml`, merge (else the recreated PVC
   tries to bind the dead node's PV and stays Pending).
2. ```
   kubectl -n ntfy scale deploy/ntfy --replicas=0
   kubectl -n ntfy delete pod -l app.kubernetes.io/name=ntfy --force --grace-period=0
   kubectl -n ntfy delete pvc ntfy-data      # Argo recreates it → Pending (WaitForFirstConsumer); else `argocd app sync ntfy`
   kubectl apply -f workloads/ntfy/_restore/restore-job.yaml   # first consumer → volume lands on a live node
   kubectl -n ntfy logs -f job/ntfy-restore
   kubectl -n ntfy delete -f workloads/ntfy/_restore/restore-job.yaml
   kubectl -n ntfy scale deploy/ntfy --replicas=1
   ```
3. Verify: `kubectl exec -n ntfy deploy/ntfy -- ntfy user list` shows the expected users/ACL; the next
   ops-alerter run logs no `ERROR: ntfy publish failed`; UptimeRobot back to UP.
4. Later: optionally re-pin the new `volumeName` via PR; delete the dead node's Released PV when sure.

*Drill (2026-11-13, PASS):* scratch ns on `k3s-cp-3`, PVC + this Job (namespace sed'ed, `NotIn k3s-cp-1`
affinity), then a ntfy pod started with CLI flags **without `upstream-base-url`** (so nothing reaches
phones via ntfy.sh). Results: users=7 tokens=5 acl=8, user/ACL list identical to prod; the real
ops-alerter token → `200` on `homelab-ops`, `403` on a non-granted topic; anonymous → `403` (deny-all).

## Escalation / depends-on

- **⚠️ ntfy is the alert channel for Story 4.2.** Until 4.2 lands there is **no alert on ntfy's
  own failure** (chicken-and-egg) — watch ntfy manually, especially during/just after cutover.
- **Publishers:** Kuma (uptime alerts) + n8n (workflow notifications). Both stay on Compose until
  their own Epic 4 cutovers; they reach ntfy via the public host, so the cloudflared flip is
  transparent to them.
- **Depends on:** Longhorn (PVC), Traefik + cert-manager (`ntfy-tls`, `letsencrypt-prod`),
  the `DOMAIN_NTFY` render token, the `ntfy-backup-r2` SealedSecret.
- **Compose ntfy RETIRED 2026-06-19 (Story 5.4)** — k3s is the sole production path; there is no
  Compose rollback. Recovery is k3s-native: restore from R2 (`homelab-k3s-services-backup/ntfy/`)
  into a scratch namespace, or `git revert` + ArgoCD sync. See [DECISIONS.md](../DECISIONS.md).
