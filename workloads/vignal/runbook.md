# Runbook: vignal

## What it does

vignal collector: ONE CronJob (`vignal`, every 6h, `concurrencyPolicy: Forbid`) running `vignal run`. The ten stages run in order: lock → intake → discover → observe → reconcile → compute → publish → purge → backup → report.

- Reads the YouTube Data API (daily quota cap in code).
- Publishes a data batch to the R2 bucket `vignal-public` (manifest last, CDN purge).
- Keeps an age-encrypted DB backup in `vignal-private/backups/` (14 kept).
- Sends ntfy alerts to topic `vignal-ops`.
- Pings a Kuma Push monitor on success.

State lives in one SQLite file on PVC `vignal-data` (local-path-retain). There is no Service or Ingress. App repo: `github.com/sushistack/vignal` (docs/ops/deploy.md, docs/ops/backup-restore.md).

> Spec deviation (2026-09-30): the app's original "`make deploy` from laptop / plaintext Secret example / GitOps Deferred" is replaced by this GitOps workload.

## Health check (exact command → expected output)

- `kubectl -n vignal get cronjob vignal` → `SUSPEND False`, with `LAST SCHEDULE` ≤ 6h ago.
- `kubectl -n vignal get jobs --sort-by=.metadata.creationTimestamp | tail -3` → the latest job shows `Complete 1/1`.
- `kubectl -n vignal logs job/<latest> | tail -5` → JSON log lines, and the last run ends with the report stage and no `level":"ERROR"`.
- Uptime Kuma: the vignal Push monitor is UP. Its heartbeat interval is **43200 s (12h = 2 × 6h)**, which is how a dead collector gets noticed (FR-23).
- `curl -sI https://<data host>/manifest.json` → `200`, `cache-control: public, max-age=60`.

## If DOWN do this (in order)

1. Read the last job's logs: `kubectl -n vignal logs job/<name>`. `runs.summary` in the DB and `vignal-private/ops/runs/<run_id>.json` hold the twelve-item summary.
2. If the failure is a publish preflight "schema-support" error, check that the web (vignal-web Worker) is deployed and serves `/schema-support.json`.
3. To run once by hand: `kubectl -n vignal create job --from=cronjob/vignal vignal-manual-$(date +%s)`. This works even while the CronJob is suspended.
4. Runaway usage or cost → **kill switch** (next section).

## Kill switch

**Commit `spec.suspend: true` in `workloads/vignal/cronjob.yaml` (PR → merge).** ArgoCD then applies it.

**Do NOT** use `kubectl patch cronjob vignal -p '{"spec":{"suspend":true}}'`. ArgoCD `selfHeal` reverts manual changes, so a patch is not a kill switch here.

To resume, commit `suspend: false`. The in-code daily quota cap (`quota.daily_cap`, ≤ 8000 units) is the second layer.

## Common failures

- **`실행 중, 잠시 후 다시 시도`**: another run holds the lock. `Forbid` normally prevents this; a stale lock (heartbeat older than 120 min) is taken over automatically.
- **Publish preflight failure**: the run fails and no upload happens. The previous batch stays live (FR-23).
  - Causes: `schema-support` (the web is not live or does not support this schema major), `format_rules` (the hash changed without a version bump), or a private-field scan hit.
- **`purge_incomplete` alert**: the CDN purge failed. The run still succeeds, and URLs are retried from `purge_queue` on the next run.
- **Quota exhausted**: the remaining work is flagged `quota_delayed` and is not retried that day.
- **Image pull error**: the `ghcr-sushistack` pull cred is expired or revoked. Re-seal it for ns `vignal`.

## Backup/restore commands

- **Backups** are written by the collector itself: `vignal-private/backups/vignal-<run_id>.db.age`. They are encrypted to `AGE_RECIPIENT`; the private key is kept off-cluster.
- **Restore**: follow the app repo's `docs/ops/backup-restore.md`.
  1. Suspend via git first.
  2. Download and decrypt the backup.
  3. Replace `/data/vignal.db` on the PV.
  4. Run `vignal restore-check`.
  5. Resume. The first run does a full refresh before it can publish.
- **Export** (free-tier exit): `vignal export --out /tmp/vignal-export.tar` from a debug pod mounting the PVC.

## Secrets

`vignal-secrets` holds `YOUTUBE_API_KEY`, the three `R2_*` values, `CF_API_TOKEN`, `NTFY_URL`, `NTFY_TOKEN`, `HEALTHCHECKS_URL` and `AGE_RECIPIENT`.

- Values live only in the git-ignored `secrets.env`. Seal them with `./seal.sh`, which writes `sealedsecret.yaml`.
- To rotate: re-seal and commit (PR). The next CronJob run reads the new values.
- The ntfy user `vignal` has write-only access to `vignal-ops` (token auth).

## Escalation / depends-on

- R2 buckets `vignal-public` / `vignal-private`.
- Cloudflare (purge + GraphQL analytics).
- YouTube Data API quota.
- ntfy (`workloads/ntfy`).
- Uptime Kuma (`workloads/uptime-kuma`).
- The sealed-secrets controller.
- The render tokens `DOMAIN_VIGNAL_SITE`, `DOMAIN_VIGNAL_DATA`, `VIGNAL_CF_ZONE_ID` and `VIGNAL_CF_ACCOUNT_ID` in `argocd-render-tokens`.
