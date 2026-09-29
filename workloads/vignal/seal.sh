#!/usr/bin/env bash
# Seal vignal-secrets (namespace vignal) from a local, untracked secrets.env.
# Values live only in secrets.env (git-ignored by *.env); only the sealed output is committed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/secrets.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found (copy secrets.env.example and fill it)" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

KEYS=(
  YOUTUBE_API_KEY
  R2_ACCESS_KEY_ID
  R2_SECRET_ACCESS_KEY
  R2_ENDPOINT
  CF_API_TOKEN
  NTFY_URL
  NTFY_TOKEN
  HEALTHCHECKS_URL
  AGE_RECIPIENT
)

args=()
for var in "${KEYS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is empty in secrets.env" >&2
    exit 1
  fi
  args+=(--from-literal="$var=${!var}")
done

kubectl create secret generic vignal-secrets -n vignal "${args[@]}" \
  --dry-run=client -o yaml | \
  kubeseal \
    --controller-name sealed-secrets \
    --controller-namespace sealed-secrets \
    -o yaml > "$SCRIPT_DIR/sealedsecret.yaml"

echo "Done → sealedsecret.yaml updated"
