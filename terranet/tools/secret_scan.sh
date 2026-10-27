#!/usr/bin/env bash
# Terranet secret scan (fail-closed). Usage: terranet/tools/secret_scan.sh <rev-list args>   e.g. v4.19.1..HEAD
# 1) gitleaks (official image, read-only mount) over the given commit range, 2) the lab's own generated secrets must not
# appear in any scanned commit, 3) tracked .env/key/dump files outside upstream's known set. Any finding exits non-zero.
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel); cd "$ROOT"
RANGE=("$@"); [ ${#RANGE[@]} -gt 0 ] || { echo "usage: $0 <rev-list args>" >&2; exit 2; }
command -v docker >/dev/null || { echo "secret scan: docker not available -> refusing (fail-closed)" >&2; exit 2; }
fail=0

echo "[1/3] gitleaks on: ${RANGE[*]}"
docker run --rm -v "$ROOT:/repo:ro" zricethezav/gitleaks:latest git /repo --log-opts="${RANGE[*]}" --redact --no-banner || fail=1

echo "[2/3] lab secret values must not appear in scanned commits"
if [ -f terranet/lab/.env ]; then
  while IFS='=' read -r k v; do
    case "$k" in SECRET_KEY_BASE|ACTIVE_RECORD_ENCRYPTION_*|POSTGRES_PASSWORD|REDIS_PASSWORD)
      [ -n "$v" ] && [ "${#v}" -ge 8 ] && if git grep -q -F -- "$v" $(git rev-list "${RANGE[@]}") 2>/dev/null; then echo "  LEAK: value of $k found in history"; fail=1; fi;;
    esac
  done < terranet/lab/.env
fi

echo "[3/3] files that must never be committed"
bad=$(git diff --name-only --diff-filter=AM "${RANGE[@]}" 2>/dev/null | grep -E '(^|/)\.env($|\.[a-z]+$)|\.(pem|key|p12|pfx|sql|dump|sqlite3?)$|id_(rsa|ed25519)|\.secret' | grep -vE '\.env\.example$|config/rds-ca-.*\.pem$|\.circleci/' || true)
[ -z "$bad" ] || { echo "$bad" | sed 's/^/  forbidden file: /'; fail=1; }

[ "$fail" -eq 0 ] && echo "secret scan: CLEAN" || { echo "secret scan: FINDINGS -> abort"; exit 1; }
