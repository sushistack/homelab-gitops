---
title: 'Netdata monitoring workload (parent + children streaming)'
type: 'feature'
created: '2026-06-22'
status: 'done'
baseline_commit: '170a1f0ac01bc0cacfc63e55645f86b54922301b'
context:
  - '{project-root}/workloads/beszel/'
  - '{project-root}/versions.yaml'
  - '{project-root}/internal/tokens.example.env'
  - '{project-root}/infra/sealed-secrets/README.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `kubectl top` gives instant node/pod resource numbers but no history and no UI. We want always-on node + per-pod CPU/mem/disk/net with a central web dashboard and local long-horizon history across the 3 k3s nodes — Netdata as the heavier-detail companion to beszel/kuma/ntfy (NOT Prometheus/Grafana).

**Approach:** New `workloads/netdata/` workload mirroring beszel's hub+agent → Netdata parent+children shape. Parent = Deployment + Longhorn PVC (dbengine history) + Service + internal-only IngressRoute + Certificate (central dashboard, long retention). Children = DaemonSet (1/node) collecting host + per-pod cgroup metrics and streaming to the parent. Auto-registered by the `workloads` ApplicationSet git-directory generator (namespace `netdata`); no hand-written ArgoCD Application.

## Boundaries & Constraints

**Always:**
- Image digest-pinned mirror in `versions.yaml` (`netdata-parent` + `netdata-children`, same `netdata/netdata` image); `bin/version-lint` must pass.
- Ingress host via `${SECRET:DOMAIN_NETDATA}` render token (never hardcoded); add the token to `internal/tokens.example.env`. TLS via cert-manager `letsencrypt-prod` ClusterIssuer + Certificate (`secretName: netdata-tls`), Traefik IngressRoute.
- `kustomization.yaml` keeps the repo patterns: `labels: includeSelectors:false`, `configMapGenerator` with `disableNameSuffixHash:true`; Deployment/DaemonSet selector + pod labels hand-written `app.kubernetes.io/name`.
- Internal-only exposure (kuma/beszel pattern): IngressRoute + Certificate + the standard `external-dns` cfargotunnel target annotation; LAN-only DNS override is an operator/runbook step, not a manifest.
- Telemetry off (`DO_NOT_TRACK=1`, no claim token); built-in health alarms off (`[health] enabled = no`).
- **Least privilege on children** (review blockers): caps add `SYS_PTRACE` ONLY — `SYS_ADMIN` is NOT granted by default (it only buys per-container network/socket detail; opt-in later if needed). Children web UI OFF (`[web] mode = none`) so the hostNetwork DaemonSet does NOT expose an unauthenticated dashboard on every node's `:19999` — only the parent serves a UI.
- **Streaming API key is a credential → SealedSecret** (`netdata-stream`), NOT a committed ConfigMap (repo is public; a plaintext shared key must not land in git). Mounted as a file via Secret `subPath` (the `envFrom`-only contract governs env injection, not file mounts). Sealed with `kubeseal` against this cluster's cert.

**Ask First:**
- History retention / PVC size beyond the default (~15d tier-0 / 10Gi).
- Granting children RBAC beyond per-pod naming (e.g. the `k8s_state` cluster-state collector needs `services/configmaps/secrets/deployments/jobs` — NOT granted by default).

**Never:** No Prometheus/Grafana/PromQL (arch rejected a heavy metrics stack). No `:latest`. No hand-written ArgoCD Application. No clusterwide `secrets` read for the children. No `SYS_ADMIN`/privileged children by default. No plaintext streaming key in git. No Docker/containerd socket mount (containerd — N/A).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output | Error Handling |
|----------|--------------|-----------------|----------------|
| Child streams up | child boots with correct `api key`+`destination` | node appears in parent dashboard with live charts | — |
| Per-pod naming | cgroup-name.sh queries node kubelet `/pods` (k3s kubelet serves a self-signed cert → TLS verify MUST be skipped) | pods show real `namespace/pod` names | RBAC/kubelet/TLS failure → falls back to cgroup id (no crash, degraded) |
| Wrong api key | child key not in parent | stream rejected, node absent | child retries (`reconnect delay`), no crash |
| Parent restart | Recreate on RWO PVC | history survives via `/var/cache/netdata` PVC | startupProbe gates readiness |

</frozen-after-approval>

## Code Map

- `workloads/beszel/*` -- template being mirrored (kustomization labels rule, internal-only IngressRoute+Middleware, Certificate, PVC Prune=false, DaemonSet tolerations/hostNetwork)
- `argocd/applicationsets/workloads.yaml` -- git-directory generator auto-registers `workloads/netdata` (namespace=netdata); no Application file needed
- `versions.yaml` (`workloads:` block) -- add `netdata-parent` + `netdata-children` (image: `netdata/netdata:v2.10.3`)
- `internal/tokens.example.env` -- add `DOMAIN_NETDATA=` (DOMAIN_* enum)
- `bin/version-lint` -- requires each manifest to literally contain `image: <ref>` from versions.yaml
- `infra/sealed-secrets/README.md` -- `kubeseal --fetch-cert` flow for sealing the `netdata-stream` SealedSecret (load-bearing — the stream key lives here)

## Tasks & Acceptance

**Execution:**
- [x] `workloads/netdata/namespace.yaml` -- `Namespace netdata`
- [x] `workloads/netdata/serviceaccount.yaml` -- ServiceAccount `netdata-children` + ClusterRole (`pods` get/list/watch; `nodes/proxy` get; `namespaces` get) + ClusterRoleBinding -- minimal per-pod-naming RBAC for children only (parent needs none)
- [x] `workloads/netdata/netdata-parent.conf` -- `[db] mode=dbengine` + tier-0 retention (~15d), bind `0.0.0.0:19999`, `[health] enabled=no`, `[ml] enabled=no` -- mounted at `/etc/netdata/netdata.conf`
- [x] `workloads/netdata/netdata-child.conf` -- `[db] mode=ram` (streams to parent), `[health] enabled=no`, **`[web] mode = none`** (no per-node dashboard on hostNetwork) -- mounted at `/etc/netdata/netdata.conf`
- [x] `workloads/netdata/sealedsecret.yaml` -- SealedSecret `netdata-stream` with data keys `stream-parent.conf` (`[<UUID>] enabled=yes`, `allow from=*`, `default memory mode=dbengine`) and `stream-child.conf` (`[stream] enabled=yes`, `destination=netdata.netdata.svc.cluster.local:19999`, `api key=<UUID>`). Operator step: generate UUID → plaintext Secret → `kubeseal --fetch-cert … | kubeseal` → commit only the sealed form
- [x] `workloads/netdata/pvc.yaml` -- Longhorn RWO 10Gi `netdata-cache` (Prune=false, dbengine history at `/var/cache/netdata`)
- [x] `workloads/netdata/deployment-parent.yaml` -- parent (Recreate, RWO PVC), `image: netdata/netdata:v2.10.3`, PVC→`/var/cache/netdata`, emptyDir→`/var/lib/netdata`, ConfigMap subPath `netdata-parent.conf`→`/etc/netdata/netdata.conf`, Secret subPath `stream-parent.conf`→`/etc/netdata/stream.conf`, `DO_NOT_TRACK=1`, probes on `:19999`, requests/limits
- [x] `workloads/netdata/daemonset-children.yaml` -- 1/node, same image, `serviceAccountName: netdata-children`, `hostPID:true`, `hostNetwork:true`+`ClusterFirstWithHostNet`, caps add **`SYS_PTRACE` only** (NO `SYS_ADMIN`), control-plane/master tolerations, mounts `/proc→/host/proc`(ro) `/sys→/host/sys` `/etc/os-release→/host/etc/os-release`(ro), ConfigMap subPath `netdata-child.conf`→`/etc/netdata/netdata.conf` + Secret subPath `stream-child.conf`→`/etc/netdata/stream.conf`, env `USE_KUBELET_FOR_PODS_METADATA=1`+`KUBELET_URL=https://localhost:10250`+`DO_NOT_TRACK=1` (k3s kubelet is self-signed; netdata's cgroup-name.sh already queries it with `curl -k`, so NO TLS-skip env exists or is needed), `/host/sys` RO, os-release hostPath `type: File`, ~256Mi limit
- [x] `workloads/netdata/service.yaml` -- ClusterIP `netdata` `:19999`
- [x] `workloads/netdata/certificate.yaml` -- `netdata-tls`, dnsName `${SECRET:DOMAIN_NETDATA}`, issuer `letsencrypt-prod`
- [x] `workloads/netdata/ingressroute.yaml` -- Middleware (https redirect) + websecure IngressRoute (svc `netdata:19999`, `tls: netdata-tls`, external-dns cfargotunnel target annotation) + web redirect IngressRoute -- host `${SECRET:DOMAIN_NETDATA}`
- [x] `workloads/netdata/kustomization.yaml` -- resources list (incl. `sealedsecret.yaml`); `labels: includeSelectors:false` (instance/part-of/managed-by shared, name hand-written per component); `configMapGenerator name: netdata-config` (the 2 `netdata-*.conf` files only — stream confs are in the Secret) + `generatorOptions: disableNameSuffixHash:true`
- [x] `versions.yaml` -- add `netdata-parent`→deployment-parent.yaml and `netdata-children`→daemonset-children.yaml, both `image: netdata/netdata:v2.10.3`
- [x] `internal/tokens.example.env` -- add `DOMAIN_NETDATA=` with a comment (internal-only, `netdata.<internal-zone>`)

**Acceptance Criteria:**
- Given the manifests, when `kubectl kustomize workloads/netdata/` runs, then it renders with no errors and the configMapGenerator emits a stable `netdata-config` (no hash suffix).
- Given the rendered output, when `bin/version-lint` runs, then both netdata entries report `✓ pins netdata/netdata:v2.10.3` and there are no floating-ref failures.
- Given a `DOMAIN_NETDATA` value in `internal/tokens.env`, when `bin/render` processes the tree, then no stray `${SECRET:...}` remains in netdata manifests.
- Given the workload synced, when the parent dashboard loads, then all 3 children appear as nodes and per-pod charts show real `namespace/pod` names (not cgroup hashes).
- Given the children pods, when their spec is inspected, then capabilities add `SYS_PTRACE` only (no `SYS_ADMIN`, not privileged) and no child serves an HTTP dashboard on `:19999`.

## Spec Change Log

- **2026-06-22 — step-04 review (no loopback).** 3-reviewer adversarial pass (blind / edge / acceptance). No intent_gap, no bad_spec, no acceptance violations. Patches applied to the diff: `/host/sys` → `readOnly: true` (2 reviewers — RO shrinks blast radius, netdata only reads cgroups; matches beszel `/sys` RO); os-release hostPath → `type: File` (guard against silent empty-dir mount). Spec text fix: the kubelet "TLS-verify-skip" was mis-described as an env element — netdata hardcodes `curl -k`, so no env exists/needed (code was already correct). Deferred (see deferred-work.md): child MACHINE_GUID non-persistence, AR29 parent+child digest co-swap, optional child readiness probe. Rejected as repo-convention/intent-consistent: namespace omission (ArgoCD sets destination ns), external-dns single-route, unauthenticated UI behind CF Access, probe/fsGroup/256Mi/progressDeadline (all match beszel/kuma or the stated intent).

## Design Notes

Single image, role by config. Netdata does **not** expand env vars in `.conf` files (issue #16491), so config ships as whole files (ConfigMap for non-secret `netdata.conf`, SealedSecret for `stream.conf`) via subPath — not env. **subPath mounts do NOT hot-reload on ConfigMap/Secret change** — after editing config or rotating the key, `kubectl -n netdata rollout restart` the parent + children. dbengine history is at `/var/cache/netdata` (NOT `/var/lib/netdata`); v2 retention uses `[db] dbengine tier 0 retention time/size`, not legacy `disk space MB`. cgroup v2 needs only `/host/sys` (no separate cgroup mount, no containerd socket). Children run `hostNetwork` so `KUBELET_URL=https://localhost:10250` hits the node's own kubelet — whose serving cert is **self-signed on k3s**, so the kubelet query must skip TLS verification or per-pod naming silently degrades to cgroup ids. `SYS_ADMIN` is deliberately omitted (review): it only adds per-container net/socket detail and is near-root on a control-plane node — opt-in if that detail is later wanted. The shared streaming UUID is both the child `[stream] api key` and the parent `[<UUID>]` section header; it lives only in the SealedSecret (the repo is public).

## Verification

**Commands:**
- `kubectl kustomize workloads/netdata/` -- expected: clean render, no errors
- `kubectl kustomize workloads/netdata/ | kubectl apply --dry-run=server -f -` -- expected: all objects validate server-side
- `bin/version-lint` -- expected: `✓` for both netdata entries, no floating-ref failure
- `kubectl kustomize workloads/netdata/ | grep -c 'SYS_ADMIN'` -- expected: `0` (children least-privilege)
- `kubectl -n netdata top pod` / parent Netdata UI -- expected: 3 child nodes + per-pod named charts (real names, not cgroup hashes → confirms kubelet TLS-skip works)

**Manual checks (if no CLI):**
- Parent dashboard reachable at `https://${DOMAIN_NETDATA}` (internal/LAN); children visible; history persists across a parent pod restart.

## Suggested Review Order

**Assembly & design intent**

- Start here: what's included, the SealedSecret-not-ConfigMap call, the labels/configMapGenerator pattern.
  [`kustomization.yaml:7`](../../workloads/netdata/kustomization.yaml#L7)

**Streaming topology (parent ↔ children)**

- Parent: dbengine PVC at `/var/cache/netdata`, config + stream.conf via subPath, Recreate.
  [`deployment-parent.yaml:64`](../../workloads/netdata/deployment-parent.yaml#L64)
- Children DaemonSet: hostNetwork/hostPID, host mounts, kubelet env for per-pod naming.
  [`daemonset-children.yaml:35`](../../workloads/netdata/daemonset-children.yaml#L35)
- Shared `:19999` ClusterIP — fronts dashboard + the stream receiver children dial.
  [`service.yaml:9`](../../workloads/netdata/service.yaml#L9)

**Security surface (the review-driven core)**

- Least privilege: caps add `SYS_PTRACE` only, no `SYS_ADMIN`; `/host/sys` RO.
  [`daemonset-children.yaml:54`](../../workloads/netdata/daemonset-children.yaml#L54)
- Minimal children RBAC: pods/namespaces/nodes-proxy only — no clusterwide secrets.
  [`serviceaccount.yaml:21`](../../workloads/netdata/serviceaccount.yaml#L21)
- Streaming key sealed (name+ns bound), never plaintext in git.
  [`sealedsecret.yaml:1`](../../workloads/netdata/sealedsecret.yaml#L1)

**Config & exposure**

- Retention/health-off (parent) and web-off/db=ram (child) netdata.conf.
  [`netdata-parent.conf:12`](../../workloads/netdata/netdata-parent.conf#L12)
- Internal-only IngressRoute + cert (kuma/beszel pattern, tokenized host).
  [`ingressroute.yaml:17`](../../workloads/netdata/ingressroute.yaml#L17)

**Mirror & token (peripherals)**

- Version SSOT mirror (both roles, same image); version-lint enforces.
  [`versions.yaml:166`](../../versions.yaml#L166)
- `DOMAIN_NETDATA` render-token declaration.
  [`tokens.example.env:37`](../../internal/tokens.example.env#L37)
