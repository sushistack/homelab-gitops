---
title: 'Dashboard migration: Heimdall → Homepage'
type: 'feature'
created: '2026-06-23'
status: 'done'
baseline_commit: '6337350ed6ac4d36c366f252221804d68beb6911'
context:
  - '{project-root}/workloads/komga/'
  - '{project-root}/workloads/heimdall/'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The homelab dashboard runs on Heimdall, whose tile layout lives only in a Longhorn-backed SQLite DB (not in git) — config drift and no declarative source of truth.

**Approach:** Replace it with `ghcr.io/gethomepage/homepage`, a stateless dashboard whose tiles are declared as a ConfigMap in git. Inherit Heimdall's exact host and INTERNAL (CF Access) exposure grade, migrate every tile, then delete `workloads/heimdall/` so the ApplicationSet prunes its Application.

## Boundaries & Constraints

**Always:**
- Follow repo conventions per `docs/deploy-prompts/session-1-homepage.md`: digest-pinned image (`@sha256` + re-resolve command + date comment), `namespace.yaml` / `kustomization.yaml` (resources listed) / `deployment.yaml` / `service.yaml`, resources requests+limits, startup/readiness/liveness probes, `env TZ=Asia/Seoul`.
- Inherit Heimdall's exposure verbatim: Host `${SECRET:DOMAIN_HEIMDALL}`, external-dns target annotation `761ca633-e9d6-4af8-8508-727bba00f0a9.cfargotunnel.com`, INTERNAL via CF Access. Pattern = komga `suwayomi` block (websecure :443 route + web :80 → https redirect Middleware + cert-manager Certificate DNS-01, `secretName homepage-tls`, ClusterIssuer `letsencrypt-prod`). All `traefik.io/v1alpha1`.
- Set `HOMEPAGE_ALLOWED_HOSTS=${SECRET:DOMAIN_HEIMDALL}` (Homepage rejects requests otherwise).
- Migrate all tiles below into `services.yaml`; group as in Heimdall.

**Ask First:**
- Any change to the `argocd-render-tokens` Secret or `internal/tokens.env` (none expected — host token already exists).
- Adding a new public DNS host or a new `DOMAIN_*` token.

**Never:**
- No PVC / Longhorn / backup-cronjob / chown initContainer — Homepage is stateless (config from ConfigMap). No `containo.us` API. No plaintext secrets. No `kubectl apply` to the cluster.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Page load | GET `https://<heimdall host>/` through CF Access | Homepage renders all migrated tiles | N/A |
| Host validation | Request Host header = the host | 200 (allowed-hosts matches) | mismatch → Homepage 400; fixed by `HOMEPAGE_ALLOWED_HOSTS` |
| heimdall dir removed | `workloads/heimdall/` deleted from git | ApplicationSet (prune:true) deletes `heimdall` Application + namespace | retained PV orphaned on Longhorn (acceptable) |

</frozen-after-approval>

## Code Map

- `workloads/heimdall/ingressroute.yaml` — exposure to inherit (host, CF Access target annotation, redirect middleware)
- `workloads/komga/ingressroute.yaml` (suwayomi block) — INTERNAL IngressRoute + Certificate golden pattern
- `workloads/komga/services.yaml`, `namespace.yaml`, `kustomization.yaml` — manifest structure
- `workloads/_template/runbook.md` — runbook skeleton (six required H2s)
- `argocd/applicationsets/workloads.yaml` — git-dir generator, prune:true (no edit needed; homepage auto-managed, heimdall auto-pruned)
- `internal/tokens.env` — confirms `DOMAIN_HEIMDALL=heimdall.eli.kr` + every tile host

## Tasks & Acceptance

**Execution:**
- [x] `workloads/homepage/namespace.yaml` -- namespace `homepage`
- [x] `workloads/homepage/config/{settings,services,widgets,bookmarks}.yaml` + `kustomization.yaml` `configMapGenerator` (hashed → auto-rollout, netdata precedent) -- declarative tiles. Replaces the single `configmap.yaml` task.
- [x] `workloads/homepage/deployment.yaml` -- digest-pinned `ghcr.io/gethomepage/homepage` (v1.13.2); env `TZ=Asia/Seoul` + `HOMEPAGE_ALLOWED_HOSTS=${SECRET:DOMAIN_HEIMDALL}`; `envFrom homepage-secrets` (optional); ConfigMap volume → `/app/config`; probes on `:3000 /`; requests cpu 50m/mem 128Mi, limit mem 256Mi
- [x] `workloads/homepage/service.yaml` -- ClusterIP `homepage` port 3000
- [x] `workloads/homepage/ingressroute.yaml` -- websecure route + web→https redirect Middleware, external-dns target annotation, Host `${SECRET:DOMAIN_HEIMDALL}`
- [x] `workloads/homepage/certificate.yaml` -- `homepage-tls`, dnsName `${SECRET:DOMAIN_HEIMDALL}`, DNS-01 letsencrypt-prod
- [x] `workloads/homepage/kustomization.yaml` -- resources + configMapGenerator + instance labels
- [x] `workloads/homepage/runbook.md` -- six H2s filled
- [x] `workloads/heimdall/` -- deleted (ApplicationSet prune:true → Application auto-removed)

**Added scope (user request, 2026-06-23):**
- [x] `config/widgets.yaml` -- info widgets: `resources` (cpu/mem/disk) + `datetime` + `openmeteo` (Seoul) + `search` — the "리소스 정보" top bar.
- [x] `config/services.yaml` proxmox tile -- `widget: type: proxmox`, url `${SECRET:IP_PROXMOX}:8006`, creds via `{{HOMEPAGE_VAR_PROXMOX_TOKEN_ID/_SECRET}}`.
- [x] `config/settings.yaml` -- 2-column max layout for narrow sidebar use (responsive: collapses to 1 col when narrow).
- [x] `workloads/homepage/sealedsecret.yaml` -- `homepage-secrets` (HOMEPAGE_VAR_PROXMOX_TOKEN_ID/_SECRET) sealed by operator + added to `kustomization.yaml` resources (2026-06-23).

**Tiles to migrate** (group · name → href, all `https://`):
- Apps: notify→notify.eli.kr, music→music.eli.kr, keep→keep.eli.kr, rss→rss.eli.kr, n8n→n8n.eli.kr, vault→vault.eli.kr, draw→draw.eli.kr
- Media: jellyfin→jellyfin.eli.kr, immich→immich.eli.kr, comics→comics.eli.kr, comics-admin→comics-admin.eli.kr, book→book.eli.kr
- Ops: argocd→argocd.eli.kr, kuma→kuma.eli.kr, semaphore→semaphore.eli.kr, traefik→traefik.eli.kr, netdata→netdata.eli.kr (beszel dropped — retired 2026-06-22, superseded by netdata)
- Infra: proxmox→proxmox.eli.kr, openwrt→openwrt.eli.kr, kvm→kvm.eli.kr

**Acceptance Criteria:**
- Given the homepage manifests, when `kustomize build workloads/homepage` runs, then it renders without error (build leaves `${SECRET:}` literal — substitution is the CMP's job at sync). It emits 8 objects: Namespace, Deployment, Service, 2×IngressRoute, Middleware, Certificate, generated ConfigMap. Config-file comments must contain NO `${SECRET:...}` token shape (they ship inside the ConfigMap and would trip the render fail-closed guard).
- Given the rendered IngressRoute, when inspected, then it carries the CF tunnel target annotation and Host `${SECRET:DOMAIN_HEIMDALL}` — exposure identical to Heimdall.
- Given `workloads/heimdall/` is deleted, when reviewed, then no other workload references it and the ApplicationSet exclude list is unchanged (heimdall was never excluded → auto-pruned).
- Given the tile list, when compared to Heimdall's documented tiles, then every live app is present (20 tiles) except `anytype` (headless sync backend, no web UI) and `beszel` (retired — see Design Notes).

## Spec Change Log

- **2026-06-23 (step-04 review, iter 1) — all patches, no loopback:**
  - **[BLOCKER] render fail-closed:** a `${SECRET:DOMAIN_*}` token shape sat in a `config/services.yaml` comment; `configMapGenerator` embeds comments into the ConfigMap, so the render CMP's fail-closed guard would `exit 1` and the Application would never sync. Reworded to drop the token shape. KEEP: host tokenization (renders correctly).
  - **Stale tile:** removed `beszel` (retired 2026-06-22, superseded by netdata) — dead link. Tiles 21→20.
  - **Un-specced security scope:** removed `NODE_TLS_REJECT_UNAUTHORIZED=0` from the shipped deployment (disables ALL outbound TLS verification, not just Proxmox). Self-signed-cert handling deferred to the PENDING proxmox-secret step (prefer `NODE_EXTRA_CA_CERTS`), documented in deployment comment + runbook.
  - **Spec accounting:** AC1 "6 resources"→8 objects; tile-count AC 21→20.
- **2026-06-23 (post-review) — host renegotiated by operator (supersedes frozen "inherit DOMAIN_HEIMDALL"):** dashboard moved off the inherited `heimdall.eli.kr` to a dedicated **`homepage.eli.kr`**, **INTERNAL-only (LAN)**. Manifests now use `${SECRET:DOMAIN_HOMEPAGE}` (Host ×2, Certificate, HOMEPAGE_ALLOWED_HOSTS); external-dns set to `controller: none` (HARD-LOCK, no public record — proxmox model) instead of the CF tunnel target. Operator handles CF Access separately. Out-of-band required before/with push: add `DOMAIN_HOMEPAGE=homepage.eli.kr` to the `argocd-render-tokens` Secret (added to internal/tokens.env + tokens.example.env here) and a LAN DNS record `homepage.eli.kr → 10.0.0.101`. `DOMAIN_HEIMDALL` token retired.
- **2026-06-23 (deploy) — two live-deploy fixes:**
  - **Pod crash-loop (2 layers):** Homepage v1.13.2 needs `/app/config` writable — it `mkdir`s `logs/` AND copies skeleton config files (kubernetes.yaml/docker.yaml) there at startup; the read-only ConfigMap mount made both fatal (`ENOENT`/`EROFS`). Fixed by seeding a writable `emptyDir` at `/app/config` from the ConfigMap via a busybox init container. (Corrects the earlier "harmless EROFS" assumption.)
  - **CF Access record:** reverted `external-dns controller: none` back to the CF tunnel **target** annotation (`761ca633-…cfargotunnel.com`) on the websecure route so external-dns publishes the public CNAME that CF Access gates (redirect route stays `controller: none` to avoid double-management). Operator confirmed CF Access is configured; LAN wildcard handles local resolution. This restores the original Heimdall INTERNAL-via-CF-Access model.
- **2026-06-23 (post-review) — Proxmox widget activated:** operator sealed `homepage-secrets` (added to kustomization, build now 9 objects). Widget URL set to `https://${SECRET:DOMAIN_PROXMOX}` (proxmox.eli.kr) instead of `IP_PROXMOX:8006` — the FQDN is fronted by this cluster's Traefik with a valid LE cert (`edge-proxies/proxmox.yaml`), so TLS verifies and NO NODE_TLS relaxation is needed. Residual: proxmox.eli.kr is LAN-only DNS (external-dns HARD-LOCK) — the homepage pod must resolve it via the LAN resolver; if it can't, add `hostAliases` → Traefik LB IP.

## Design Notes

- **Host inheritance:** reuse `${SECRET:DOMAIN_HEIMDALL}` (heimdall.eli.kr) rather than minting `DOMAIN_HOMEPAGE` — avoids editing the git-ignored tokens.env and the out-of-band `argocd-render-tokens` Secret. A future rename to a `homepage.*` host is a separate task.
- **anytype omitted:** listed among Heimdall's migrated apps but has no browser UI (desktop client → headless sync server); no `DOMAIN_ANYTYPE` exists. Not a clickable tile.
- **Writable /app/config (init-seeded):** Homepage v1.13.2 bootstraps missing config files (kubernetes.yaml/docker.yaml/…) AND a logs dir into `/app/config` at startup, and **crash-loops if that dir is read-only** (the original "harmless EROFS" assumption was wrong twice over). So `/app/config` is a writable `emptyDir` seeded from the read-only ConfigMap by a `busybox` init container; Homepage fills in the rest. ConfigMap hash still drives auto-rollout. No PVC (no persistent data).
- **Icons:** use Homepage's built-in `<slug>.png` dashboard-icon convention (e.g. `icon: ntfy.png`) — no asset files to ship.

## Verification

**Commands:**
- `kubectl kustomize workloads/homepage` -- expected: exit 0, 8 objects, no errors
- `kubectl kustomize workloads/homepage | grep -oE '\$\{SECRET:[^}]*\}' | grep -vE '\$\{SECRET:[A-Z0-9_]+\}'` -- expected: no output (no malformed token shapes that would trip render fail-closed)
- `grep -rn heimdall workloads/ --include='*.yaml' | grep -vi DOMAIN_HEIMDALL` -- expected: no matches (only the inherited host token remains)

**Manual checks:**
- IngressRoute YAML carries `external-dns.alpha.kubernetes.io/target: 761ca633-…cfargotunnel.com` and `entryPoints: [websecure]` + a separate `web` redirect route — matches komga suwayomi block.
- Tile count in `services.yaml` == 20 (the list above).

## Suggested Review Order

**Exposure (highest leverage — inherits Heimdall verbatim)**

- Entry point: INTERNAL host + CF tunnel target annotation, identical to old Heimdall route.
  [`ingressroute.yaml:10`](../../workloads/homepage/ingressroute.yaml#L10)
- web→https redirect + websecure both match the inherited `DOMAIN_HEIMDALL` host.
  [`ingressroute.yaml:15`](../../workloads/homepage/ingressroute.yaml#L15)
- DNS-01 cert, new `homepage-tls` secret for the same FQDN.
  [`certificate.yaml:7`](../../workloads/homepage/certificate.yaml#L7)

**Runtime**

- Digest-pinned image (v1.13.2) + re-resolve comment; `HOMEPAGE_ALLOWED_HOSTS` required or 400s.
  [`deployment.yaml:20`](../../workloads/homepage/deployment.yaml#L20)
- `homepage-secrets` optional envFrom + self-signed-TLS note (PENDING the Proxmox token).
  [`deployment.yaml:34`](../../workloads/homepage/deployment.yaml#L34)
- configMapGenerator → hashed name rolls the Deployment when config changes (netdata precedent).
  [`kustomization.yaml:13`](../../workloads/homepage/kustomization.yaml#L13)

**Dashboard content (the migration payload)**

- 20 tiles, tokenized hosts; the fail-closed comment fix lives at the top.
  [`services.yaml:6`](../../workloads/homepage/config/services.yaml#L6)
- Proxmox widget wiring (creds via runtime `{{HOMEPAGE_VAR_*}}`).
  [`services.yaml:88`](../../workloads/homepage/config/services.yaml#L88)
- Top info bar: system resources + clock + weather.
  [`widgets.yaml:3`](../../workloads/homepage/config/widgets.yaml#L3)
- 2-column max for narrow sidebar use (responsive collapse).
  [`settings.yaml:9`](../../workloads/homepage/config/settings.yaml#L9)

**Peripherals**

- Runbook (six H2s) — health check, if-DOWN, Proxmox-token rotation.
  [`runbook.md:1`](../../workloads/homepage/runbook.md)
