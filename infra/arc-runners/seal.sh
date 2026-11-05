#!/usr/bin/env bash
# Seal `arc-github` (namespace arc-runners) — the PAT the vignal runner scale set registers with.
# The token lives only in the untracked arc-github.env (git-ignored by *.env); only the sealed output is committed.
#   GITHUB_TOKEN=<fine-grained PAT: repo sushistack/vignal, Administration: Read and write, Metadata: Read>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-$SCRIPT_DIR/arc-github.env}"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found (one line: GITHUB_TOKEN=...)" >&2; exit 1; }
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a
[[ -n "${GITHUB_TOKEN:-}" ]] || { echo "ERROR: GITHUB_TOKEN is empty" >&2; exit 1; }

kubectl create secret generic arc-github -n arc-runners --from-literal="github_token=$GITHUB_TOKEN" \
  --dry-run=client -o yaml | \
  kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets -o yaml \
  > "$SCRIPT_DIR/sealedsecret.yaml"
echo "Done -> sealedsecret.yaml"
