#!/usr/bin/env bash
# Story 5.8 (AC6b) — apply the 5 external-host EndpointSlices OUT OF BAND.
#
# WHY out-of-band: ArgoCD's cluster-wide resource.exclusions (argocd-cm) excludes BOTH core/v1
# Endpoints AND discovery.k8s.io/EndpointSlice (the standard default — it stops ArgoCD watching the
# thousands of control-plane-generated endpoint objects). So ArgoCD silently drops the manual
# EndpointSlices in this dir (the app shows ExcludedResourceWarning, not a sync of them). The
# Services / Certificates / IngressRoutes ARE ArgoCD-managed; only these 5 static slices are not.
#
# They are static (one backend IP:port each) and a selector-less Service never auto-manages or prunes
# them, so they persist once applied. RE-RUN THIS after a cluster rebuild (or if a slice is deleted).
# This is the reproducibility mechanism — the YAML in this dir stays the source of truth; render
# substitutes the real backend IPs from internal/tokens.env into the (git-ignored) rendered/ tree.
#
# Usage (from repo root, with internal/tokens.env populated):  bash workloads/edge-proxies/apply-endpoints.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
for h in proxmox openwrt jellyfin immich kvm; do
  bin/render "workloads/edge-proxies/$h.yaml" >/dev/null
done
python3 - "$tmp" <<'PY'
import glob, sys
out = open(sys.argv[1], "w")
for f in sorted(glob.glob("rendered/workloads/edge-proxies/*.yaml")):
    for doc in open(f).read().split("\n---\n"):
        if "kind: EndpointSlice" in doc:
            out.write(doc.strip() + "\n---\n")
out.close()
PY
kubectl apply -f "$tmp"
rm -rf rendered/workloads/edge-proxies
echo "EndpointSlices applied. Verify: kubectl -n edge-proxies get endpointslice"
