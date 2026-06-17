#!/bin/sh
# Self-check for the in-cluster render filter (render-stdin.sh), the POSIX-sh twin of
# bin/render that the ArgoCD render CMP runs at sync time. It substitutes ${SECRET:NAME}
# tokens into kustomize output and must FAIL CLOSED rather than ship a broken value.
#
# The script under test is the one actually deployed: it lives inside the
# `render-stdin.sh` block of ansible/argocd-values.yaml. We extract that block (no second
# copy to drift) and exercise the edge cases that bit us in review.
#
#   sh bin/test-render-stdin.sh
set -eu
cd "$(dirname "$0")/.."

VALUES=ansible/argocd-values.yaml
SCRIPT=$(mktemp)
trap 'rm -f "$SCRIPT" /tmp/_rt.env' EXIT

# Pull the 8-space-indented block under `render-stdin.sh: |`, stop at the next dedent.
awk '
  /^      render-stdin\.sh: \|/ { grab=1; next }
  grab {
    if ($0 == "") { print ""; next }
    if ($0 !~ /^        /) { exit }
    sub(/^        /, ""); print
  }
' "$VALUES" > "$SCRIPT"
[ -s "$SCRIPT" ] || { echo "FAIL: could not extract render-stdin.sh from $VALUES" >&2; exit 1; }

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL [$1]: got [$2] want [$3]" >&2; fi; }
# expect render to exit non-zero (fail closed)
expect_fail() { if printf '%s' "$2" | RENDER_TOKENS="$3" sh "$SCRIPT" >/dev/null 2>&1; then
  fail=$((fail+1)); echo "FAIL [$1]: expected non-zero exit" >&2; else pass=$((pass+1)); fi; }

printf 'DOMAIN_DRAW=draw.example.test\n' > /tmp/_rt.env
check happy "$(printf 'Host(`${SECRET:DOMAIN_DRAW}`)' | RENDER_TOKENS=/tmp/_rt.env sh "$SCRIPT")" 'Host(`draw.example.test`)'

# empty value must NOT become Host(``) — fail closed
printf 'DOMAIN_DRAW=\n' > /tmp/_rt.env
expect_fail empty-value 'Host(`${SECRET:DOMAIN_DRAW}`)' /tmp/_rt.env

# sed metachars in the value pass through literally, no abort
printf 'DOMAIN_DRAW=a|b&c\\d\n' > /tmp/_rt.env
check sed-metachars "$(printf 'X=${SECRET:DOMAIN_DRAW}' | RENDER_TOKENS=/tmp/_rt.env sh "$SCRIPT")" 'X=a|b&c\d'

# CRLF and trailing whitespace trimmed
printf 'DOMAIN_DRAW=draw.example.test\r\n' > /tmp/_rt.env
check crlf "$(printf 'H[${SECRET:DOMAIN_DRAW}]' | RENDER_TOKENS=/tmp/_rt.env sh "$SCRIPT")" 'H[draw.example.test]'
printf 'DOMAIN_DRAW=draw.example.test   \n' > /tmp/_rt.env
check trailing-ws "$(printf 'H[${SECRET:DOMAIN_DRAW}]' | RENDER_TOKENS=/tmp/_rt.env sh "$SCRIPT")" 'H[draw.example.test]'

# non-[A-Z_] key skipped -> token stays unresolved -> fail closed
printf 'bad-key=x\n' > /tmp/_rt.env
expect_fail bad-key-name '${SECRET:bad-key}' /tmp/_rt.env

# token-free manifest passes through even with no tokens file
check token-free "$(printf 'plain: yaml\n' | RENDER_TOKENS=/nonexistent sh "$SCRIPT")" 'plain: yaml'

echo "render-stdin self-check: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
