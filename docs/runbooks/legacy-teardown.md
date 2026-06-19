# Runbook — Final legacy teardown + R2 monitor + ntfy topic split + Heimdall + full NPM retirement

Story 5.8 (Epic 5 / Phase 3, post-DONE). **DEV authored every manifest in this repo; the LIVE steps
below are operator-run.** Forward-only — there is no rollback net after this (5.4's parked volumes +
`*.retired-5.4` files ARE the net, and this story removes it; the migration is DONE with restores
verified from R2). Non-gating: stopping after any section is fine.

> **Plane 0 is never touched.** cloudflared (the public edge) stays exactly as is. OpenWrt edits are
> surgical + review-gated. Nothing under `configs/oracle/` or `configs/proxmox/` is in scope.

Conventions (redacted per the exposure gate — substitute your real values): `<Z>` = your public DNS
zone; IPs are the last octet on the `10.0.0.0/24` LAN (`.20` = the Compose host, `.101/.102/.103` =
the three k3s servers, `.100` = the NanoKVM, `.1` = the OpenWrt gateway).

Host shorthand: `H = root@.20` (the LIVE Compose host — shared project with cloudflared, so
**delete by explicit name, never `docker compose down -v`**); the edge re-point target is
`https://<node>:443` (a k3s server, `.101`).

---

## Section A — Legacy teardown (AC1)

### A1. Delete inventory — parked app Compose volumes + retired files (on H)

Enumerate, **don't guess**:

```sh
ssh root@.20 'docker volume ls --format "{{.Name}}"'
```

Delete the volumes belonging to the **migrated applications only**. The seven app cutovers (Epic 4)
+ draw (Epic 1) are off Compose: `excalidraw draw / ntfy notify / navidrome music / anytype /
karakeep keep / miniflux rss / n8n / vaultwarden vault`. Their Compose volumes are the parked
rollback net.

```sh
# by EXPLICIT name — confirm each against the ls output first
ssh root@.20 'docker volume rm <app-volume-1> <app-volume-2> ...'
# retired host files left by 5.4
ssh root@.20 'find /opt/docker -name "*.retired-5.4" -print -delete'
```

**KEEP (do NOT delete here):**
- `cloudflared` volume — Plane 0, never touched.
- the `uptime-kuma` and `NPM` (`nginx-proxy-manager`) volumes — they are still LIVE-serving the six
  hosts until **Section E** cuts them over. After Section E completes, the **surviving infra volume
  set is cloudflared only**.

### A2. Delete dead NPM proxy-hosts (NPM UI on H)

Delete the proxy-hosts whose backends are already gone or shadowed:
- `portainer`, `homepage` — retired in 5.5 (backends down).
- the seven migrated-app shadows — `notify`, `music`, `anytype`, `keep`, `rss`, `n8n`, `vault`
  (CF tunnel already routes these straight to k3s; the NPM entries are dead shadows).

**Do NOT delete** `jellyfin / immich / proxmox / openwrt / kvm / kuma` proxy-hosts yet — those six
are migrated in **Section E**, then NPM is deleted whole.

### A3. Verify (after A1+A2)

```sh
# all 7 migrated public hosts still serve from k3s
for h in notify music anytype keep rss n8n vault draw; do
  echo -n "$h: "; curl -s -o /dev/null -w "%{http_code}\n" "https://$h.<Z>"   # expect 200/302/307
done
ssh root@.20 'docker volume ls'   # app volumes gone; cloudflared + NPM + uptime-kuma remain
```

### A4. OpenWrt reconcile — VERIFY repo == live (AC1c, read-only unless drift)

Repo is already clean (`home`/`portainer` overrides pruned in `f41776a`). Confirm live matches —
**surgical `--check --diff`, never a blind full apply** (memory `openwrt_dns_apply_drift`):

```sh
cd configs/openwrt && make <check-diff-target>   # show drift only; 0 diff on home/portainer => done
```

If (and only if) drift exists, apply the single offending line with `uci del_list/add_list` +
`dnsmasq reload`, not a full playbook run. Coordinate the window with any in-flight 5.6/5.7 OpenWrt
staging.

---

## Section B — R2 backup monitor (AC2)

The check is folded into the existing `*/15` **ops-alerter** CronJob (`infra/ops-alerts/`) — not a
new system. It is **dormant until you seal the cred** (the R2 block in `alert.sh` is a no-op while
`RCLONE_CONFIG_R2_TYPE` is unset).

### B1. Seal the R2 cred (reuse ntfy-backup-r2's value)

The R2 token is identical to `ntfy-backup-r2`; only the seal target (name+ns) changes.

```sh
# dump the live cred values, then reseal to (ops-alerts-r2, ns ops-alerts):
kubectl -n ntfy get secret ntfy-backup-r2 -o json \
  | jq -r '.data | to_entries[] | "\(.key)=\(.value|@base64d)"' > /tmp/r2.env   # 5 RCLONE_CONFIG_R2_* keys
kubectl create secret generic ops-alerts-r2 -n ops-alerts --dry-run=client -o yaml --from-env-file=/tmp/r2.env \
  | kubeseal --controller-namespace sealed-secrets --format yaml > infra/ops-alerts/sealedsecret-r2.yaml
shred -u /tmp/r2.env
```

Then uncomment **both** in the repo:
- `infra/ops-alerts/kustomization.yaml` → `- sealedsecret-r2.yaml`
- `infra/ops-alerts/cronjob.yaml` → the `- secretRef: name: ops-alerts-r2` envFrom

Commit + push → ArgoCD syncs. (Same reseal recipe applies to `uptime-kuma-backup-r2` in Section E.)

### B2. Thresholds (env on the CronJob — already set, tune if needed)

| env | default | meaning |
|-----|---------|---------|
| `R2_THRESHOLD_GB` | 8 | per-bucket size alert (before the ~10 GB free tier) |
| `R2_STALE_HOURS` | 13 | newest object in a `<svc>/` prefix older than this ⇒ **backup actor silently broke** |
| `R2_RETENTION_DAYS` | 35 | oldest object older than this ⇒ **rotation broke** (the 4.8 `\|\| true` blind spot) |

Buckets scanned: `homelab-k3s-services-backup` (per-`<svc>/` freshness+rotation+size) and
`homelab-k3s-backup` (size only — Longhorn's own layout isn't `<svc>/`).

**No NetworkPolicy delta:** `ops-alerter-egress` already allows `0.0.0.0/0:443`, which covers both R2
(HTTPS) and the apk CDN (`apk add rclone` over HTTPS). Confirmed against `networkpolicy.yaml`.

### B3. Verify

```sh
# force a run and read the log
job=ops-alerter-manual-$(date +%s)
kubectl -n ops-alerts create job "$job" --from=cronjob/ops-alerter
kubectl -n ops-alerts logs -f job/"$job"     # prints per-bucket size + any STALE/OLD verdicts
```
Dry-run a positive: set `R2_THRESHOLD_GB=0` temporarily → one `💽 R2 용량 임박` alert on
`homelab-critical` → revert. The parse logic (date math + group-by) is unit-checked:
`sh infra/ops-alerts/test-r2-parse.sh`.

Condition → action map:

| alert | topic | action |
|-------|-------|--------|
| `💽 R2 용량 임박` | critical | prune old backups / raise R2 plan / shorten `RETENTION_DAYS` |
| `🥪 백업 신선도 경고` | critical | the `<svc>-backup` CronJob stopped producing — `kubectl -n <svc> get cronjob,job`, check logs |
| `🗑️ 백업 미회전` | critical | `rclone delete` retention is failing (perms or the `\|\| true`) — check the actor's delete step |

---

## Section C — ntfy topic split by concern (AC3)

Three topics, split by **concern, not per-app** (per-app = 15 subscriptions of mostly-silence; see
DECISIONS.md). Per-app filtering is the app-name title prefix + ntfy tags/priority **within** a topic.

| topic | concern | source |
|-------|---------|--------|
| `homelab-critical` | stateful/backup failures (NFR15a) + R2 capacity/freshness/rotation | ops-alerter (a–d + R2) |
| `homelab-ops` | drift/health (NFR15b): ArgoCD OutOfSync, k3s version drift, node NotReady | ops-alerter (e–g) |
| `homelab-monitor` | node CPU/mem/disk/net | Beszel `shoutrrr` (5.7, operator-set) |

### C1. Grant topic ACLs (ntfy is `auth-default-access: deny-all`)

The ops-alerter token user keeps its existing identity — just grant it `wo` (write-only) on the two
topics it now publishes to. On the ntfy server (H, or `kubectl exec` once kuma/ntfy is in-cluster):

```sh
ntfy access <ops-alerter-user> homelab-critical wo
ntfy access <ops-alerter-user> homelab-ops      wo
ntfy access <beszel-user-or-token> homelab-monitor wo   # if Beszel shoutrrr uses a token
```
No `server.yml` change and **no SealedSecret reseal** — same token, more topic grants. (If you'd
rather scope a fresh token per concern, that's optional; the single-user-multi-topic grant is the
lazy-correct path.)

### C2. Beszel shoutrrr target (coordinate with 5.7)

Set Beszel's optional `shoutrrr` notification URL to the monitor topic:
`ntfy://<ntfy-host>/homelab-monitor` (or token form). This is configured in Beszel's UI/settings per
5.7 — **not** a manifest edit here.

### C3. Operator subscription set (subscribe in the ntfy mobile/web app)

- **`homelab-critical`** — push + sound on (wake me).
- **`homelab-ops`** — push on, sound off (review when convenient).
- **`homelab-monitor`** — muted/badge-only (glance).

### C4. Verify

Publish one test message per topic; confirm it lands on that topic **only**:
```sh
for t in homelab-critical homelab-ops homelab-monitor; do
  curl -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
    -d "{\"topic\":\"$t\",\"title\":\"test $t\",\"message\":\"routing check\"}" https://notify.<Z>
done
```

---

## Section D — Populate Heimdall (AC4; gated on 5.7 done — 5.7 IS done)

**This tile list IS the deliverable** — 5.7 shipped Heimdall with no backup actor on the claim that
its config is "trivially reproducible." This list makes that true: after a PVC loss, re-create from
here. If your Heimdall build has Settings → Backup/Export, export the JSON and attach it next to this
file (`docs/runbooks/heimdall-export.json`) — it beats a prose list. Do **not** build tile-as-code.

Groups + tiles (URLs are the `*.<Z>` public hosts / internal hosts):

**Apps (migrated)** — `notify` (ntfy), `music` (navidrome), `anytype`, `keep` (karakeep),
`rss` (miniflux), `n8n`, `vault` (vaultwarden), `draw` (excalidraw).
**Media (kept)** — `jellyfin`, `immich`, `comics` (komga), `comics-admin` (suwayomi), `book` (calibre).
**Ops / platform** — ArgoCD, `kuma` (uptime-kuma), Beszel, Semaphore.
**Infra UIs** — Proxmox, OpenWrt, NanoKVM (`kvm`).

Enhanced/live-status tiles: enable **only** where the tile type needs no new secret (plain ping/HTTP
status). If you want a live tile that needs an API key (e.g. a service's stats API), seal it as a
SealedSecret first — don't paste a key into Heimdall's DB by hand (it won't survive a PVC loss).

After clicking: confirm the dashboard renders on LAN (`heimdall.<internal-zone>` → `.101`), then
this list (or the export) is the recovery path.

---

## Section E — Full NPM retirement (AC6): kuma → k3s, 5 externals → Traefik, delete NPM

Completes `architecture.md:145` (Traefik absorbs the NPM role). **Forward-only; NPM + token deleted
ONLY after all six verify on Traefik.** cloudflared untouched.

### E1. kuma → k3s (workloads/uptime-kuma — DEV-authored, stateful cutover)

1. Seal the backup cred (same recipe as B1, target `uptime-kuma-backup-r2` / ns `uptime-kuma`), then
   uncomment `backup-cronjob.yaml` + `sealedsecret.yaml` in `workloads/uptime-kuma/kustomization.yaml`.
2. **Quiesce + migrate data** (memory `cutover_data_consistency` — SQLite background writers):
   ```sh
   ssh root@.20 'docker stop <uptime-kuma-container>'          # freeze the DB
   ssh root@.20 'docker run --rm -v <kuma-vol>:/d -v /root:/o alpine cp /d/kuma.db /o/kuma.db'
   scp root@.20:/root/kuma.db ./kuma.db
   kubectl apply -f workloads/uptime-kuma/_cutover/ingest-job.yaml    # parks the PVC (run BEFORE the Deployment)
   pod=$(kubectl -n uptime-kuma get pod -l job-name=uptime-kuma-ingest -o name | head -1)
   kubectl -n uptime-kuma cp ./kuma.db "${pod#pod/}:/data/kuma.db"
   kubectl -n uptime-kuma exec "${pod#pod/}" -- sha256sum /data/kuma.db   # BYTE-VERIFY vs source kuma.db
   kubectl -n uptime-kuma delete -f workloads/uptime-kuma/_cutover/ingest-job.yaml
   ```
3. Commit/push the kustomization (app + ingressroute + cert) → ArgoCD brings up kuma against the
   populated PVC. Confirm `kubectl -n uptime-kuma get pod` Ready + `uptime-kuma-tls` Ready.

### E2. Five externals → Traefik (workloads/edge-proxies — DEV-authored)

Fill the tokens in `internal/tokens.env`: `DOMAIN_{KUMA,JELLYFIN,IMMICH,PROXMOX,OPENWRT,KVM}` and
`IP_{JELLYFIN,IMMICH,OPENWRT,KVM}` (`IP_PROXMOX` already set). **CONFIRM each backend port/scheme
against the live NPM nginx conf on H before flipping** — the manifests default jellyfin→http:8096,
immich→http:2283, kvm→http:80, proxmox→https:8006, openwrt→https:443. Commit/push → ArgoCD creates
the headless Services + EndpointSlices + per-host Certificates + IngressRoutes in ns `edge-proxies`.

### E3. Per-host edge re-point (one at a time, verify before the next)

Mirrors the 4.x tunnel-flip. For each of `kuma jellyfin immich proxmox openwrt kvm`:

```sh
# re-point the cloudflared route for <host> from NPM (.20) to https://<node>:443,
# originServerName=<host>.<Z>  (cfd_tunnel ingress API — memory cf_tunnel_flip)
# then VERIFY before moving on:
curl -s -o /dev/null -w "%{http_code}\n" "https://<host>.<Z>"   # expect 200/302/307 from k3s
```
Also flip the LAN OpenWrt DNS override for each host `.20 → .101` (surgical `uci
del_list`/`add_list` + `dnsmasq reload`, not a full apply). `note.<Z>` and `chat.<Z>` are out
of scope (not NPM-fronted-by-this-story — leave them).

### E4. Delete NPM + revoke the legacy token (ONLY after all six are green on Traefik)

```sh
ssh root@.20 'docker rm -f <npm-container>'                 # by explicit name
ssh root@.20 'docker volume rm <npm-volume> <npm-db-volume>'
ssh root@.20 'docker ps'                                    # expect: cloudflared ONLY
```
Revoke CF DNS token **`ca7e70a5`** in the Cloudflare dashboard (the legacy NPM token). **Keep
cert-manager's token `3b2b473a`** — confirm certs still renew (`kubectl get certificate -A`).

### E5. External watcher + LAN recovery (AC6e)

kuma now lives in-cluster, so it can't be its own out-of-band watcher for a **total k3s outage**. Add
**one** off-site ping:
- Cloudflare Health Check + notification on `https://notify.<Z>` (or kuma's own host), **or**
- a free external monitor (e.g. an UptimeRobot HTTP check) on the same host.

**LAN recovery during a k3s outage** (the externals' edge depends on Traefik on `.101`): reach the
infra UIs by **LAN IP, not <Z>** —
- Proxmox: `https://<IP_PROXMOX>:8006`
- OpenWrt: `https://<IP_OPENWRT>` (the gateway — this is also how you fix DNS if k3s is down)
- NanoKVM: `http://.100`

These never depended on k3s before and the IP path is unchanged; only the `*.<Z>` convenience name
routes through Traefik now.

---

## Done-state checklist

- [ ] App Compose volumes + `*.retired-5.4` gone on H; dead NPM proxy-hosts deleted; OpenWrt 0 drift.
- [ ] ops-alerts-r2 sealed + uncommented; ops-alerter log prints R2 sizes; forced alert fired once.
- [ ] 3 topics subscribed; one test publish per topic landed on the right topic only.
- [ ] Heimdall renders all groups on LAN; tile list (or export) captured here.
- [ ] kuma in k3s, data byte-verified; 5 externals serve from Traefik; NPM deleted (cloudflared only);
      token `ca7e70a5` revoked, `3b2b473a` still renewing; external ping live.
