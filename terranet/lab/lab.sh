#!/usr/bin/env bash
# Terranet lab helper. Run from anywhere: terranet/lab/lab.sh <command>
set -euo pipefail
cd "$(dirname "$0")"
DC="docker compose"

TEST_ENV=(-e RAILS_ENV=test -e POSTGRES_DATABASE=chatwoot_test -e REDIS_URL=redis://redis:6379/5)
# Dev tooling inside the container (annotate_rb, schema dump) rewrites tracked files such as
# app/models/*.rb, enterprise/app/models/*.rb and db/schema.rb. Run a command, then restore ONLY
# the tracked files that were clean before and became dirty during it (never pre-existing edits).
guard_tree() {
  local root before after changed
  root=$(git rev-parse --show-toplevel)
  before=$(git -C "$root" diff --name-only | sort)
  "$@"; local rc=$?
  after=$(git -C "$root" diff --name-only | sort)
  changed=$(comm -13 <(echo "$before") <(echo "$after"))
  if [ -n "$changed" ]; then
    echo "$changed" | (cd "$root" && xargs git checkout --)
    echo "guard_tree: restored $(echo "$changed" | wc -l) file(s) rewritten by dev tooling"
  fi
  return $rc
}

rand() { openssl rand -hex "${1:-32}"; }

case "${1:-help}" in
  init)      # create .env with fresh random dev secrets (refuses to overwrite)
    [ -e .env ] && { echo ".env already exists; not overwriting"; exit 0; }
    sed -e "s/ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=.*/ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$(rand 16)/" \
        -e "s/ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=.*/ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$(rand 16)/" \
        -e "s/ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=.*/ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$(rand 16)/" \
        -e "s/SECRET_KEY_BASE=.*/SECRET_KEY_BASE=$(rand 64)/" \
        -e "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(rand 12)/" \
        -e "s/REDIS_PASSWORD=.*/REDIS_PASSWORD=$(rand 12)/" env.lab.example > .env
    chmod 600 .env; echo ".env created (gitignored, dev-only secrets)";;
  build)     $DC build rails;;
  bootstrap) $DC --profile bootstrap run --rm bootstrap;;   # only step with internet: pnpm install
  up)        $DC up -d postgres redis mailpit dns-sink
             guard_tree $DC run --rm rails bundle exec rails db:chatwoot_prepare
             $DC up -d rails sidekiq vite gateway;;
  seed)      guard_tree $DC run --rm rails bundle exec rails db:seed;;   # not needed after `up` (prepare seeds a fresh DB)
  down)      $DC down;;
  reset)     $DC down -v;;                                    # destroys lab DB/Redis volumes only
  ps)        $DC ps;;
  logs)      shift; $DC logs --tail=100 "$@";;
  dns-log)   $DC logs --no-log-prefix dns-sink | grep -E 'query\[' || true;;   # FQDNs requested by the lab
  health)    curl -fsS "http://127.0.0.1:$(grep ^LAB_RAILS_PORT .env | cut -d= -f2)/api" ; echo;;
  rails)     shift; guard_tree $DC run --rm rails bundle exec rails "$@";;
  test-db)   # separate DB + Redis index so specs never touch the lab dev data
             $DC run --rm "${TEST_ENV[@]}" rails bundle exec rails db:create db:schema:load;;
  rspec)     shift; $DC run --rm "${TEST_ENV[@]}" rails bundle exec rspec "$@";;
  vitest)    shift; $DC run --rm rails pnpm test "$@";;
  *) echo "usage: $0 {init|build|bootstrap|up|seed|down|reset|ps|logs|dns-log|health|rails|test-db|rspec|vitest}";;
esac
