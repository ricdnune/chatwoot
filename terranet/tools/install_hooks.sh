#!/usr/bin/env bash
# Points this clone's hooks at terranet/tools/hooks (local git config only; nothing is pushed or committed).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
chmod +x terranet/tools/hooks/pre-push terranet/tools/secret_scan.sh
git config core.hooksPath terranet/tools/hooks
echo "hooks installed: core.hooksPath=$(git config core.hooksPath)"
