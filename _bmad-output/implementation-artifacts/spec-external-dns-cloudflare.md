---
title: 'Stage 1 — external-dns (Cloudflare) for public *.eli.kr DNS automation'
type: 'feature'
created: '2026-06-22'
status: 'done'
baseline_commit: '036772ff605fcd4ec92cc5ad5129d8b2da26d729'
context:
  - '{project-root}/docs/public-host-automation.md'
  - '{project-root}/infra/cloudflared/'
  - '{project-root}/infra/ops-alerts/'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Public CF DNS for `*.eli.kr` is hand-maintained in the CF dashboard (toil + drift per new host); the internal/public gate is an implicit "did I make a CNAME" discipline.

**Approach:** Deploy `external-dns` (Cloudflare, `--source=traefik-proxy`) as a wave-2 infra Application that watches Traefik IngressRoutes and reconciles public CNAMEs. `--policy=upsert-only` (never deletes). **Gate = whitelist / opt-in** (deny-by-default): a route is published ONLY if it carries an `external-dns.alpha.kubernetes.io/target` annotation; no annotation ⇒ no record ⇒ NXDOMAIN. Sensitive infra UIs additionally get `controller: none` (hard-lock).

## Boundaries & Constraints

**Always:**
- Args: `--source=traefik-proxy`, `--provider=cloudflare`, `--domain-filter=eli.kr`, `--zone-id-filter=4367617624907bc338dd9eda8ab5e561`, `--txt-owner-id=homelab-k3s`, `--registry=txt`, `--policy=upsert-only`, `--cloudflare-proxied` (bare flag = true). **NO `--default-targets`** — verified ignored by the traefik-proxy source in v0.21.0; the target comes from the per-route annotation.
- Public hosts opt in with `external-dns.alpha.kubernetes.io/target: 26586f61-9c31-4d40-b8c5-8898b1e567e3.cfargotunnel.com` on the websecure route (the 12 already match live CF records → first sync is a no-op; new hosts get CNAME+TXT created).
- Sensitive infra UIs hard-locked with `controller: none`: `argocd, proxmox, openwrt, kvm` (all their routes). Other internal hosts need NOTHING (no target = private).
- Mirror cloudflared conventions: pinned image in `versions.yaml`, SealedSecret sealed to exact ns/name, `labels:` (never namePrefix/commonLabels).

**Ask First:**
- Promoting `--policy=sync` (enables deletion). Out of scope for this stage.
- Adding a `target` to any currently-internal host (it would publish it).

**Never:**
- Do not touch the cloudflared deployment/tunnel (that is Stage 2).
- Do not set `--policy=sync`, `--cloudflare-proxied=false`, omit `--domain-filter`, or re-add `--default-targets`.
- Do not hand-edit CF dashboard records.
- Do not add a new chart/Helm source — self-authored kustomize only (cloudflared/ops-alerts pattern).

## I/O & Edge-Case Matrix

| Scenario | State | Expected Behavior |
|----------|-------|-------------------|
| Existing public host | `vault.eli.kr` route has `target`; CF record already CNAME→tunnel | endpoint generated, matches live → no-op (no change) |
| New public host | new route + `target` annotation | CNAME→tunnel + TXT created (proxied) |
| Internal host (passive) | route has NO annotation | source emits no endpoint → no record → NXDOMAIN |
| Sensitive host | route has `controller: none` | resource skipped entirely; a stray `target` still won't publish |
| anytype | manual direct-A (116.120.13.87), HostSNI(`*`) | no target, no hostname → external-dns never touches it |
| CF token invalid | bad/expired token | auth error in logs; upsert-only = no destructive change |

</frozen-after-approval>

## Code Map

- `infra/external-dns/namespace.yaml` -- `external-dns` namespace (new)
- `infra/external-dns/{serviceaccount,rbac}.yaml` -- SA + ClusterRole/binding: `traefik.io` ingressroutes/tcp/udp + core services/endpoints/pods/nodes get/list/watch
- `infra/external-dns/sealedsecret.yaml` -- `cloudflare-api-token` (key `CF_API_TOKEN`), reuses `CLOUDFLARE_DNS01_TOKEN` (DNS:Edit, eli.kr — verified zone-listable)
- `infra/external-dns/deployment.yaml` -- `registry.k8s.io/external-dns/external-dns`, args above, `envFrom: cloudflare-api-token`
- `infra/external-dns/kustomization.yaml` -- bundle + `labels:` (cloudflared pattern)
- `argocd/apps/external-dns.yaml` -- Application `sync-wave: "2"`, self-authored kustomize
- `versions.yaml` -- add `workloads.external-dns` pinned image (version-lint)
- 12 public IngressRoutes -- add `target` annotation (whitelist opt-in): vaultwarden, n8n, miniflux, excalidraw, karakeep, navidrome, ntfy, ntfy-web, komga, calibre, immich, jellyfin
- 4 sensitive hosts -- `controller: none` hard-lock (all routes): argocd-ui, proxmox(+redirect), openwrt(+redirect), kvm(+redirect)

## Tasks & Acceptance

**Execution:**
- [x] `infra/external-dns/{namespace,serviceaccount,rbac}.yaml` -- created; ClusterRole get/list/watch on traefik.io ingressroutes/tcps/udps + core services/endpoints/pods/nodes + endpointslices
- [x] `infra/external-dns/sealedsecret.yaml` -- sealed `cloudflare-api-token` (CF_API_TOKEN) against live controller (`--controller-name sealed-secrets --controller-namespace sealed-secrets` — note: svc is `sealed-secrets`, not the kubeseal default)
- [x] `infra/external-dns/deployment.yaml` -- external-dns v0.21.0, replicas 1, Recreate, all Always args, securityContext hardened. SWAP TO @sha256 at apply (AR29)
- [x] `infra/external-dns/kustomization.yaml` -- bundle resources + `labels:` (includeSelectors:false)
- [x] `argocd/apps/external-dns.yaml` -- Application wave 2, path `infra/external-dns`, automated+prune+ServerSideApply
- [x] `versions.yaml` -- added `workloads.external-dns` pinned to the deployment image (version-lint ✓ on this entry)
- [x] public IngressRoutes -- `target` annotation on 12 websecure routes (whitelist opt-in): vaultwarden, n8n, miniflux, excalidraw, karakeep, navidrome, ntfy, ntfy-web, komga, calibre, immich, jellyfin
- [x] sensitive IngressRoutes -- `controller: none` hard-lock on 7 routes: argocd-ui, proxmox(+redirect), openwrt(+redirect), kvm(+redirect). Other internal (traefik/semaphore/heimdall/beszel/suwayomi/kuma/anytype) = NO annotation (fail-closed)
- [x] **dry-run verified (live, --dry-run --once):** 12 public generate endpoints matching live records → plan = "All records already up to date" (0 CREATE/UPDATE/DELETE); sensitive skipped; passive-internal emit no endpoint. Also caught + fixed `--cloudflare-proxied=true` crash (must be bare flag).

**Acceptance Criteria:**
- Given external-dns synced, when `kubectl -n external-dns logs deploy/external-dns` is read, then no DELETE/UPDATE on existing public CNAMEs (dry-run already showed "all up to date"); new public hosts later get CNAME+TXT.
- Given a public host route with `target`, when external-dns reconciles, then it emits `host → tunnel` matching the live record (no-op for the existing 12).
- Given an internal host with NO `target` (or `controller: none`), when external-dns reconciles, then no record is created (NXDOMAIN gate); a stray `target` on a `controller:none` host still publishes nothing.
- Given `bin/version-lint`, when run, then the external-dns entry passes. NOTE: lint overall is RED on a pre-existing, unrelated issue — `versions.yaml` points trade-monitor at the deleted `cronjob.yaml` (HEAD 036772f migrated it to a Deployment). Not in scope.

## Spec Change Log

- **2026-06-22 (review loop 1, patch)** — Reviewers found the internal-gate set INCOMPLETE. **Trigger:**
  `docs/DECISIONS.md` (2026-06-19, Story 5.8 AC6a/AC6b) locked `kuma, proxmox, openwrt, kvm` to
  INTERNAL-only; their public CF records are stale leftovers (cleanup deferred), so the CF-zone "ground
  truth" mis-read them as public. **Amended:** added `controller: none` to those 4 hosts (kuma+redirect,
  proxmox, openwrt, kvm = 5 routes). **Known-bad avoided:** external-dns adopting sensitive infra UIs
  (hypervisor/gateway/IPMI/monitoring) as managed-public → latent exposure once the tunnel goes catch-all
  (Stage 2) or policy is promoted to sync. **FROZEN CORRECTION (human-owned, needs ratification):** the
  "Always" bullet's "the only repo hosts with no current public record" is wrong — internal ≠ no-record
  for these 4. **KEEP:** the gate RULE (internal ⇒ `controller: none`) and the upsert-only + proxied=true
  no-op-adoption design.
- **2026-06-22 (review loop 1, patch)** — Blast-radius hardening: added `--zone-id-filter=<eli.kr id>`
  (CF token is shared with cert-manager, broader than this zone) + liveness probe on `:7979/healthz`
  (a wedged reconciler otherwise silently stops all DNS updates).
- **2026-06-22 (dry-run pivot — APPROACH CHANGE, user-ratified "B")** — Live `--dry-run` proved the
  original gate design was BROKEN two ways: (1) `--cloudflare-proxied=true` crashes the pod (kingpin
  bool must be bare `--cloudflare-proxied`); (2) the traefik-proxy source ignores `--default-targets`
  in v0.21.0 — it emits NO endpoint for a host without a per-route `target` annotation, so the original
  "`--default-targets` + `controller:none` opt-out" design produced ZERO DNS records (silent no-op).
  **Re-architected to whitelist/opt-in (deny-by-default):** target comes from a per-route
  `external-dns.alpha.kubernetes.io/target` annotation (12 public hosts); absence = private. Dropped
  `--default-targets`. Reverted all 16 `controller:none` from loop-1; re-applied `controller:none` only
  as a HARD-LOCK on the 4 sensitive infra UIs (argocd/proxmox/openwrt/kvm) per user choice **B**.
  **Verified live:** 12 public endpoints match existing records → "all up to date" (0 changes); sensitive
  skipped; passive-internal emit nothing. **KEEP:** upsert-only + zone-id-filter + liveness + the
  whitelist model.

## Design Notes

# ponytail: no NetworkPolicy — cloudflared (sibling infra) has none, cluster has no default-deny; external-dns needs only apiserver + CF-API egress. Add one only if default-deny lands later.

RBAC is get/list/watch only; source is `traefik-proxy` exclusively, so the ClusterRole stays minimal.

## Verification

**Commands:**
- `bin/version-lint` -- expected: pass
- `kubectl -n external-dns logs deploy/external-dns | grep -iE 'CREATE|UPDATE|DELETE|skipping'` -- expected: TXT CREATEs only, no DELETE
- `curl -sf -H "Authorization: Bearer $CLOUDFLARE_DNS01_TOKEN" "https://api.cloudflare.com/client/v4/zones/4367617624907bc338dd9eda8ab5e561/dns_records?per_page=200"` -- expected: 18 public CNAMEs unchanged + new `external-dns-*` TXT records; no record for argocd/traefik/semaphore/heimdall/beszel/comics-admin/anytype

**Manual checks:**
- After a few stable days, promote `--policy=sync` in a follow-up (Ask First) for full reconcile.

## Suggested Review Order

**The controller (design intent)**

- Entry point — the args ARE the safety model: upsert-only + domain/zone filter + matching tunnel target.
  [`deployment.yaml:43`](../../infra/external-dns/deployment.yaml#L43)
- Why proxied=true + this tunnel id make first sync a no-op adoption (doc correction).
  [`deployment.yaml:46`](../../infra/external-dns/deployment.yaml#L46)
- Blast-radius/ops hardening from review: zone-id-filter + liveness probe.
  [`deployment.yaml:42`](../../infra/external-dns/deployment.yaml#L42)

**App wiring & SSOT**

- Wave-2 Application, self-authored kustomize (cloudflared shape).
  [`external-dns.yaml:14`](../../argocd/apps/external-dns.yaml#L14)
- Version pin mirrored for version-lint.
  [`versions.yaml:177`](../../versions.yaml#L177)
- Least-privilege read-only ClusterRole (traefik CRDs + core).
  [`rbac.yaml:10`](../../infra/external-dns/rbac.yaml#L10)
- CF token sealed to exact ns/name.
  [`sealedsecret.yaml:4`](../../infra/external-dns/sealedsecret.yaml#L4)

**The internal/public gate (security — read carefully)**

- The gate rule, one line: argocd internal → no public record.
  [`ingressroute.yaml:13`](../../infra/argocd-ui/ingressroute.yaml#L13)
- komga PUBLIC but its admin sibling suwayomi gated — the asymmetry.
  [`ingressroute.yaml:64`](../../workloads/komga/ingressroute.yaml#L64)
- Review-loop catch: sensitive infra UIs with STALE public records, gated per DECISIONS.md 5.8.
  [`proxmox.yaml:54`](../../workloads/edge-proxies/proxmox.yaml#L54)
- kuma locked internal post-cutover (stale public record left for cleanup).
  [`ingressroute.yaml:23`](../../workloads/uptime-kuma/ingressroute.yaml#L23)
