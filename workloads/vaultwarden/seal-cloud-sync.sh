#!/usr/bin/env bash
# Seal the vaultwarden-cloud-sync secret (the 7 values that were GitHub repo secrets on the now-frozen
# home.server) → sealedsecret-cloud-sync.yaml. Run on the operator workstation (kubeconfig + kubeseal
# pointed at the cluster). NOT a new key — same Vaultwarden/Bitwarden creds, just relocated into k3s.
#
# Usage (export the 7 values first, then run):
#   export VW_API_URL=https://vault.eli.kr \
#          VW_API_CLIENT_ID=... VW_API_CLIENT_SECRET=... VW_MASTER_PASSWORD=... \
#          BW_API_CLIENT_ID=... BW_API_CLIENT_SECRET=... BW_MASTER_PASSWORD=...
#   ./seal-cloud-sync.sh
# Then: add `- sealedsecret-cloud-sync.yaml` to kustomization.yaml, set suspend:false in
# cloud-sync-cronjob.yaml, commit, ArgoCD sync.
set -euo pipefail

NS=vaultwarden
NAME=vaultwarden-cloud-sync
CTRL_NS=sealed-secrets        # memory kubeseal-controller-ns (NOT kube-system)
CTRL_NAME=sealed-secrets      # this cluster's controller service name
DIR="$(cd "$(dirname "$0")" && pwd)"

command -v kubeseal >/dev/null || { echo "✗ kubeseal not on PATH" >&2; exit 1; }
for v in VW_API_URL VW_API_CLIENT_ID VW_API_CLIENT_SECRET VW_MASTER_PASSWORD \
         BW_API_CLIENT_ID BW_API_CLIENT_SECRET BW_MASTER_PASSWORD; do
  [ -n "${!v:-}" ] || { echo "✗ $v is unset" >&2; exit 1; }
done

seal() { kubeseal --controller-name "$CTRL_NAME" --controller-namespace "$CTRL_NS" --format yaml; }

kubectl create secret generic "$NAME" -n "$NS" \
  --from-literal=VW_API_URL="$VW_API_URL" \
  --from-literal=VW_API_CLIENT_ID="$VW_API_CLIENT_ID" \
  --from-literal=VW_API_CLIENT_SECRET="$VW_API_CLIENT_SECRET" \
  --from-literal=VW_MASTER_PASSWORD="$VW_MASTER_PASSWORD" \
  --from-literal=BW_API_CLIENT_ID="$BW_API_CLIENT_ID" \
  --from-literal=BW_API_CLIENT_SECRET="$BW_API_CLIENT_SECRET" \
  --from-literal=BW_MASTER_PASSWORD="$BW_MASTER_PASSWORD" \
  --dry-run=client -o yaml | seal > "$DIR/sealedsecret-cloud-sync.yaml"

echo "✅ sealed → $DIR/sealedsecret-cloud-sync.yaml"
echo "→ next: add it to kustomization.yaml, set suspend:false in cloud-sync-cronjob.yaml, commit, sync."
