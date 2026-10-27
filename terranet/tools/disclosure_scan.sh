#!/usr/bin/env bash
# Terranet disclosure scan (fail-closed). Usage: terranet/tools/disclosure_scan.sh <rev-list args>   e.g. origin/x..HEAD
# The fork is PUBLIC. gitleaks finds secrets; this finds infrastructure/PII that is not a secret: private addresses outside the lab
# ranges, key/dump/capture files, corporate e-mail addresses, and any pattern listed in the git-ignored local denylist
# (terranet/tools/disclosure_patterns.local: one extended regex per line, e.g. real node or host names, which must NEVER be committed).
# It looks only at lines ADDED by the commits about to be pushed. A finding exits non-zero; fix it or re-word it, do not bypass.
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel); cd "$ROOT"
RANGE=("$@"); [ ${#RANGE[@]} -gt 0 ] || { echo "usage: $0 <rev-list args>" >&2; exit 2; }
LOCAL=terranet/tools/disclosure_patterns.local
fail=0

# generic, safe to publish. Lab (172.29.250.x), loopback and documentation ranges are allowed.
GENERIC=(
  '(^|[^0-9.])(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-8]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
  '(^|[^0-9.])172\.29\.(24[0-9]|25[1-9]|2[6-9][0-9])\.[0-9]{1,3}([^0-9]|$)'
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.(com|ec|net|org)\b'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'ssh://|git@[a-z0-9.-]+:' # disclosure:ignore (this file names the pattern it searches for)
)
ALLOWED_EMAIL='@(example\.(com|org|net|invalid)|[a-z0-9.-]*\.invalid|users\.noreply\.github\.com|chatwoot\.com|acme\.inc|localhost)\b'

added_lines() { git log -p --no-color --format='' --diff-filter=AM "${RANGE[@]}" -- . ':(exclude)*.png' ':(exclude)*.jpg' ':(exclude)*.svg' ':(exclude)pnpm-lock.yaml' ':(exclude)*.lock' "$@" \
                | grep -E '^\+[^+]' | sed 's/^+//' || true; }
added=$(added_lines)                                  # every added line (local denylist)
# Generic patterns skip spec/ (fixtures legitimately hold addresses) and lines carrying the marker `disclosure:ignore`
# (e.g. the SSRF blocklist in the endpoint validator, which must name private ranges).
generic_added=$(added_lines ':(exclude)spec' | grep -v 'disclosure:ignore' || true)

echo "[1/3] generic patterns on lines added in: ${RANGE[*]}"
for pattern in "${GENERIC[@]}"; do
  hits=$(printf '%s\n' "$generic_added" | grep -E -- "$pattern" | grep -vEi -- "$ALLOWED_EMAIL" || true)
  if [ -n "$hits" ]; then echo "  FINDING for /$pattern/:"; printf '%s\n' "$hits" | head -5 | cut -c1-160 | sed 's/^/    /'; fail=1; fi
done

echo "[2/3] local denylist ($LOCAL)"
if [ -s "$LOCAL" ]; then
  while IFS= read -r pattern; do
    [ -z "$pattern" ] || [ "${pattern:0:1}" = "#" ] && continue
    if printf '%s\n' "$added" | grep -Eiq -- "$pattern"; then echo "  FINDING: a line matches a pattern of the local denylist (pattern not shown)"; fail=1; fi
  done < "$LOCAL"
else
  echo "  no local denylist: create $LOCAL (git-ignored) with one regex per line for names that must never be published"
fi

echo "[3/3] file types that must not be published"
bad=$(git diff --name-only --diff-filter=AM "${RANGE[@]}" | grep -E '\.(pcap|pcapng|har|sql|dump|bak|log|csv|xlsx|ovpn|kdbx)$' || true)
[ -z "$bad" ] || { printf '%s\n' "$bad" | sed 's/^/  forbidden file: /'; fail=1; }

[ "$fail" -eq 0 ] && echo "disclosure scan: CLEAN (heuristic: a human must still read new documents)" || { echo "disclosure scan: FINDINGS -> abort"; exit 1; }
