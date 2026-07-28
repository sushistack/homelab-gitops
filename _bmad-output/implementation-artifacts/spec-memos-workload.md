---
title: 'Memos self-hosted notes workload'
type: 'feature'
created: '2026-07-28'
status: 'done'
baseline_commit: '984267f561c815f94752c5582bbf346bc5064159'
context:
  - '{project-root}/workloads/ntfy/'
  - '{project-root}/versions.yaml'
  - '{project-root}/internal/tokens.example.env'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** No self-hosted quick-notes app exists in the homelab. usememos/memos (SQLite-backed, single binary, own login) fits the same "small public utility with its own auth" class already running here (ntfy, karakeep, miniflux).

**Approach:** New `workloads/memos/` copying the ntfy golden path 1:1 (single container + SQLite PVC + R2 backup CronJob + public IngressRoute + Certificate). Auto-discovered by the `workloads` ApplicationSet — no hand-written Application. Public, own-auth, same tier as karakeep/miniflux/ntfy — NOT the CF-Access admin/monitoring tier (argocd/traefik/semaphore/lidarr/langfuse class).

## Boundaries & Constraints

**Always:**
- Image pinned by digest: `neosmemo/memos@sha256:51a4cef418b1f173ac37139ad99de08da5b8662136007231d3ac8a0498a3095a` (v0.30.0) — never `:stable`/`:latest`.
- Public exposure via `external-dns.alpha.kubernetes.io/target` = the shared tunnel (`761ca633-e9d6-4af8-8508-727bba00f0a9.cfargotunnel.com`), same as karakeep/miniflux/ntfy. No CF Access.
- Host tokenized `${SECRET:DOMAIN_MEMOS}`; register `DOMAIN_MEMOS=` (default `memo.<public-zone>`) in `internal/tokens.example.env`.
- SQLite data (`/var/opt/memos`) on a `local-path-retain` PVC, `Prune=false` (real data). Deployment `strategy: Recreate` (RWO + SQLite — never RollingUpdate, per ntfy AR14).
- Backup CronJob co-schedules onto the app pod's node via `podAffinity` (RWO multi-mount trap), `sqlite3 .backup` to emptyDir `/scratch`, `rclone copy` to `r2:homelab-k3s-services-backup/memos/`, prune `--min-age 72h`, ~6h cadence — copy ntfy's actor verbatim, only the db filename/image-port change.
- `runbook.md` filled (all 6 sections, no `N/A — fill on migration` left).

**Ask First:** none — defaults (host `memo.<public-zone>`, private instance mode / first sign-up becomes owner) match the existing pattern and are safe to proceed on.

**Never:** no Postgres (SQLite is upstream's documented default, sufficient for single-operator use); no NetworkPolicy this pass (ntfy — the closest single-container precedent — has none; the cluster has no baseline default-deny yet, so this isn't a regression); no bespoke `argocd/apps/memos.yaml` (the ApplicationSet already covers this shape).

</frozen-after-approval>

## Code Map

- `workloads/ntfy/*.yaml` -- template to copy verbatim and adapt (namespace/pvc/deployment/service/certificate/ingressroute/backup-cronjob/sealedsecret/kustomization)
- `versions.yaml` -- add the `memos` image pin entry (SSOT)
- `internal/tokens.example.env` -- add `DOMAIN_MEMOS=` registry line

## Tasks & Acceptance

**Execution:**
- [x] `workloads/memos/namespace.yaml` -- `Namespace memos`
- [x] `workloads/memos/pvc.yaml` -- `memos-data`, 2Gi, `local-path-retain`, `Prune=false` -- durable SQLite store (AR15)
- [x] `workloads/memos/deployment.yaml` -- digest-pinned image, `strategy: Recreate`, port 5230, mount `memos-data`->`/var/opt/memos`, `TZ=Asia/Seoul`, TCP probes on 5230
- [x] `workloads/memos/service.yaml` -- `ClusterIP`, port 80 -> targetPort 5230
- [x] `workloads/memos/certificate.yaml` -- `memos-tls` for `${SECRET:DOMAIN_MEMOS}` via `letsencrypt-prod`
- [x] `workloads/memos/ingressroute.yaml` -- public `websecure` route (external-dns target annotation) + `web`->HTTPS redirect
- [x] `workloads/memos/backup-cronjob.yaml` -- `alpine:3.20`, `sqlite3 /data/memos_prod.db ".backup /scratch/memos_prod.db"`, tar + `rclone copy` to `r2:homelab-k3s-services-backup/memos/`, prune `--min-age 72h`, schedule `"40 */6 * * *"`, `podAffinity` to the app pod
- [x] `workloads/memos/sealedsecret.yaml` -- `memos-backup-r2` (R2 creds sealed to name+ns)
- [x] `workloads/memos/kustomization.yaml` -- wire the 8 resources above + `labels:`
- [x] `workloads/memos/runbook.md` -- fill all 6 sections from `workloads/_template/runbook.md`
- [x] `versions.yaml` -- add the `memos` image-pin entry (SSOT, NFR14)
- [x] `internal/tokens.example.env` -- add `DOMAIN_MEMOS=` registry line

**Acceptance Criteria:**
- Given `workloads/memos/` is pushed with a valid `kustomization.yaml`, when the `workloads` ApplicationSet reconciles, then an `Application` named `memos` appears Synced/Healthy with no manual Application file needed.
- Given `DOMAIN_MEMOS` is set in `internal/tokens.env` and rendered, when `https://${DOMAIN_MEMOS}` is requested, then it returns the Memos sign-in page over a browser-trusted cert (not a self-signed/staging one).
- Given the backup CronJob fires, when the job completes, then a `memos-<timestamp>.tar.gz` object exists under `r2:homelab-k3s-services-backup/memos/` and objects older than 72h are gone on the next run.
- Given the memos pod is deleted/restarted, when the new pod starts, then it reopens the same SQLite DB from the PVC (Recreate strategy, single writer) with no data loss.

## Spec Change Log

## Design Notes

No documented `/healthz` -- TCP probe on 5230 is the right gate (template default). Leave `MEMOS_INSTANCE_URL` unset -- instance stays private-mode (sign-in required, first registrant becomes owner), which is what's wanted here.

## Verification

**Commands:**
- `bin/render workloads/memos/ingressroute.yaml workloads/memos/certificate.yaml` -- expect `${SECRET:DOMAIN_MEMOS}` resolved in `rendered/`, no stray `${SECRET:...}` left
- `kubectl -n memos get pods,pvc,ingressroute,certificate` -- expect pod Running/Ready, PVC Bound, Certificate Ready
- `curl -sI https://${DOMAIN_MEMOS}` -- expect `200`/`301`
- `git diff --stat` reviewed for gitleaks compliance (only `${SECRET:NAME}` tokens, no raw domains/IPs) before commit

**Manual checks (if no CLI):**
- Open `https://${DOMAIN_MEMOS}` in a browser, complete first-run sign-up, confirm the account becomes owner/admin.

## Suggested Review Order

**Workload definition**

- Entry point — digest-pinned image, `Recreate` strategy (RWO+SQLite safety), TCP probes (no documented `/healthz`)
  [`deployment.yaml:10`](../../workloads/memos/deployment.yaml#L10)

**Public exposure**

- External-dns target annotation + tokenized host — public, own-auth tier, no CF Access
  [`ingressroute.yaml:23`](../../workloads/memos/ingressroute.yaml#L23)
- Production `letsencrypt-prod` cert for the same tokenized host
  [`certificate.yaml:10`](../../workloads/memos/certificate.yaml#L10)
- New `DOMAIN_MEMOS` registry line (real value lives in gitignored `internal/tokens.env`, not this file)
  [`tokens.example.env`](../../internal/tokens.example.env)

**Storage & backup**

- `local-path-retain` + `Prune=false` — durable, node-pinned, never auto-deleted
  [`pvc.yaml:13`](../../workloads/memos/pvc.yaml#L13)
- `podAffinity` co-schedule + `--min-age 72h` prune — online SQLite backup to R2
  [`backup-cronjob.yaml:33`](../../workloads/memos/backup-cronjob.yaml#L33)
- Real sealed R2 credential (reuses the shared bucket-scoped token, sealed to this namespace)
  [`sealedsecret.yaml`](../../workloads/memos/sealedsecret.yaml)
- Restore-time scratch pod for `kubectl cp` into the RWO PVC (ntfy cutover pattern, generalized)
  [`_restore/ingest-job.yaml`](../../workloads/memos/_restore/ingest-job.yaml)

**Wiring & peripherals**

- Resource bundle + common labels
  [`kustomization.yaml`](../../workloads/memos/kustomization.yaml)
- Image-pin SSOT entry
  [`versions.yaml`](../../versions.yaml)
- Operability: health/If-DOWN/restore procedure (node-pinned storage caveat corrected here)
  [`runbook.md:19`](../../workloads/memos/runbook.md#L19)
