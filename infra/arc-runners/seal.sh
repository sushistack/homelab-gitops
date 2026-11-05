#!/usr/bin/env bash
# Seal `arc-github` (namespace arc-runners) — the credential the vignal runner scale set registers with.
# Values live only in untracked files here (*.env / *.pem are git-ignored); only sealedsecret.yaml is committed.
#   GitHub App (preferred, no expiry): arc-github.env with GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID, and the
#     app's private key as arc-github.pem. App permission: Repository Administration read/write; installed on vignal only.
#   or a fine-grained PAT: arc-github.env with GITHUB_TOKEN (repo sushistack/vignal, Administration read/write).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/arc-github.env"
PEM_FILE="$SCRIPT_DIR/arc-github.pem"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found" >&2; exit 1; }
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

if [[ -n "${GITHUB_APP_ID:-}" ]]; then
  [[ -n "${GITHUB_APP_INSTALLATION_ID:-}" ]] || { echo "ERROR: GITHUB_APP_INSTALLATION_ID is empty" >&2; exit 1; }
  [[ -f "$PEM_FILE" ]] || { echo "ERROR: $PEM_FILE (the app private key) not found" >&2; exit 1; }
  args=(--from-literal="github_app_id=$GITHUB_APP_ID"
        --from-literal="github_app_installation_id=$GITHUB_APP_INSTALLATION_ID"
        --from-file="github_app_private_key=$PEM_FILE")
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  args=(--from-literal="github_token=$GITHUB_TOKEN")
else
  echo "ERROR: set GITHUB_APP_ID (+ installation id, pem) or GITHUB_TOKEN in $ENV_FILE" >&2; exit 1
fi

kubectl create secret generic arc-github -n arc-runners "${args[@]}" --dry-run=client -o yaml | \
  kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets -o yaml \
  > "$SCRIPT_DIR/sealedsecret.yaml"
echo "Done -> sealedsecret.yaml (now delete arc-github.env / arc-github.pem)"
