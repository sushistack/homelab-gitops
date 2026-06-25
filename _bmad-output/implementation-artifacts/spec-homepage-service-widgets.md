---
title: 'Homepage: per-service app widgets'
type: 'feature'
created: '2026-06-25'
status: 'done'
baseline_commit: '0173c4b2a3c941444c6b5e7c1c78840c4a752388'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Homepage service cards show only links and icons — no live data. The dashboard looks like a bookmark page rather than an operational panel. App-specific stats (Jellyfin active streams, Lidarr queue, Miniflux unread count, etc.) make it actionable.

**Approach:** Add Homepage `widget:` blocks to 6 service entries in `services.yaml`, pulling credentials from the existing `homepage-secrets` SealedSecret via `{{HOMEPAGE_VAR_*}}` env vars (same pattern as the Proxmox widget). Operator re-seals the Secret out-of-band adding the new var names.

## Boundaries & Constraints

**Always:**
- Credentials via `{{HOMEPAGE_VAR_*}}` in services.yaml — never inline plaintext
- Widget URLs use `${SECRET:DOMAIN_*}` tokens (consistent with href; rendered by Argo CD CMP)
- No new files; only `config/services.yaml` and `sealedsecret.yaml` (comment update only — actual sealing is operator's job)
- ConfigMap hash auto-rolls the deployment (already wired via kustomization hashing)

**Ask First:**
- If operator wants Uptime Kuma stats via API (user+pass) vs. public status page (just a slug)
- If Traefik API widget is wanted (requires Traefik's admin API accessible in-cluster; skip for now)

**Never:**
- Docker socket stats (N/A — this is Kubernetes)
- Kubernetes pod CPU/MEM metrics (no metrics-server in cluster)
- Widgets for services without official Homepage support: n8n, excalidraw, semaphore, slskd, karakeep, suwayomi
- `kubectl apply` or cluster changes

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Widget loads normally | API key present and valid, service up | App stats shown below service description | N/A |
| API key missing from Secret | `HOMEPAGE_VAR_*` env var absent | Widget shows error badge on that card; other cards unaffected | Homepage graceful degradation per-widget |
| Service unreachable | App down or DNS unresolved | Widget timeout badge on that card only | Same isolation |

</frozen-after-approval>

## Code Map

- `workloads/homepage/config/services.yaml` — add `widget:` blocks to service entries
- `workloads/homepage/sealedsecret.yaml` — add comment block documenting new HOMEPAGE_VAR_* names (operator seals out-of-band)

## Tasks & Acceptance

**Execution:**
- [x] `workloads/homepage/config/services.yaml` — add `widget:` blocks to 6 services below; use `{{HOMEPAGE_VAR_*}}` pattern (same as Proxmox):
  - **jellyfin** → `type: jellyfin`, `url: https://${SECRET:DOMAIN_JELLYFIN}`, `key: "{{HOMEPAGE_VAR_JELLYFIN_API_KEY}}"`
  - **immich** → `type: immich`, `url: https://${SECRET:DOMAIN_IMMICH}`, `key: "{{HOMEPAGE_VAR_IMMICH_API_KEY}}"`
  - **navidrome** (music) → `type: navidrome`, `url: https://${SECRET:DOMAIN_NAVIDROME}`, `user: "{{HOMEPAGE_VAR_NAVIDROME_USER}}"`, `password: "{{HOMEPAGE_VAR_NAVIDROME_PASSWORD}}"`
  - **lidarr** → `type: lidarr`, `url: https://${SECRET:DOMAIN_LIDARR}`, `key: "{{HOMEPAGE_VAR_LIDARR_API_KEY}}"`
  - **miniflux** (rss) → `type: miniflux`, `url: https://${SECRET:DOMAIN_RSS}`, `key: "{{HOMEPAGE_VAR_MINIFLUX_API_KEY}}"`
  - **uptime-kuma** (kuma) → `type: uptimekuma`, `url: https://${SECRET:DOMAIN_KUMA}`, `slug: "{{HOMEPAGE_VAR_KUMA_SLUG}}"` (public status page slug)
- [x] `workloads/homepage/sealedsecret.yaml` — add comment block listing new plaintext var names for operator to seal: `HOMEPAGE_VAR_JELLYFIN_API_KEY`, `HOMEPAGE_VAR_IMMICH_API_KEY`, `HOMEPAGE_VAR_NAVIDROME_USER`, `HOMEPAGE_VAR_NAVIDROME_PASSWORD`, `HOMEPAGE_VAR_LIDARR_API_KEY`, `HOMEPAGE_VAR_MINIFLUX_API_KEY`, `HOMEPAGE_VAR_KUMA_SLUG`

**Acceptance Criteria:**
- Given services.yaml is updated, when `kubectl kustomize workloads/homepage` runs, then exit 0 and ConfigMap contains `widget:` entries for all 6 services with no unresolved `${SECRET:}` token shapes in comments
- Given all HOMEPAGE_VAR_* env vars are sealed and deployed, when homepage pod starts, then each targeted service card shows live stats from the app
- Given a single widget's API key is wrong, when the dashboard loads, then only that card shows an error badge; all others load normally

## Spec Change Log

## Design Notes

**Widget URL = external DOMAIN token:** Consistent with the Proxmox widget pattern already live. The Argo CD CMP substitutes `${SECRET:DOMAIN_*}` at sync; homepage reaches each service over its public URL (same as the browser does). No in-cluster `svc.cluster.local` URLs needed.

**SealedSecret re-seal process:** The operator must create the full updated secret and re-seal it entirely — SealedSecret replaces the whole Secret. Keep existing Proxmox vars when re-sealing:
```sh
kubectl create secret generic homepage-secrets -n homepage \
  --from-literal=HOMEPAGE_VAR_PROXMOX_TOKEN_ID=... \
  --from-literal=HOMEPAGE_VAR_PROXMOX_TOKEN_SECRET=... \
  --from-literal=HOMEPAGE_VAR_JELLYFIN_API_KEY=... \
  --from-literal=HOMEPAGE_VAR_IMMICH_API_KEY=... \
  --from-literal=HOMEPAGE_VAR_NAVIDROME_USER=... \
  --from-literal=HOMEPAGE_VAR_NAVIDROME_PASSWORD=... \
  --from-literal=HOMEPAGE_VAR_LIDARR_API_KEY=... \
  --from-literal=HOMEPAGE_VAR_MINIFLUX_API_KEY=... \
  --from-literal=HOMEPAGE_VAR_KUMA_SLUG=... \
  --dry-run=client -o yaml | kubeseal -o yaml > workloads/homepage/sealedsecret.yaml
```

**Where to find each API key:**
- Jellyfin: Administration → Dashboard → API Keys → `+`
- Immich: User Profile (top-right) → API Keys → Create
- Navidrome: any valid user credentials (recommend read-only user)
- Lidarr: Settings → General → Security → API Key
- Miniflux: Profile → API Keys → Create
- Uptime Kuma: Status Pages → slug of a published status page (e.g. `default`)

## Verification

**Commands:**
- `kubectl kustomize workloads/homepage` — expected: exit 0, ConfigMap rendered; no `${SECRET:}` token shape in comments

**Manual checks:**
- Deploy to cluster; visit homepage.eli.kr — targeted cards (Jellyfin, Immich, Navidrome, Lidarr, Miniflux, Uptime Kuma) show live stats beneath the description
