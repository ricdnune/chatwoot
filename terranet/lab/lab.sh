#!/usr/bin/env bash
# Terranet lab helper. Run from anywhere: terranet/lab/lab.sh <command>
set -euo pipefail
cd "$(dirname "$0")"
DC="docker compose"

TEST_ENV=(-e RAILS_ENV=test -e POSTGRES_DATABASE=chatwoot_test -e REDIS_URL=redis://redis:6379/5)
ROOT=$(git rev-parse --show-toplevel)

# Never rewrites the user's tree. It snapshots every modified/untracked (non-ignored) path with a content
# hash before a command, compares afterwards and REPORTS differences (paths + diff stat); it does not
# revert anything. Exit status 3 = command succeeded but the working tree changed unexpectedly.
tree_snapshot() {
  git -C "$ROOT" status --porcelain=v1 --untracked-files=all | while IFS= read -r line; do
    path=${line:3}
    if [ -e "$ROOT/$path" ]; then printf '%s  %s\n' "$(sha1sum < "$ROOT/$path" | cut -c1-40)" "$line"; else printf 'gone  %s\n' "$line"; fi
  done | sort
}

with_tree_check() {
  local before after rc changed
  before=$(mktemp); after=$(mktemp)
  tree_snapshot > "$before"
  "$@"; rc=$?
  tree_snapshot > "$after"
  changed=$(comm -3 "$before" "$after" | sed 's/^\t//' | awk '{print $NF}' | sort -u)
  if [ -n "$changed" ]; then
    echo "WARNING: the working tree changed while running: $*" >&2
    echo "$changed" | sed 's/^/  changed: /' >&2
    # shellcheck disable=SC2046
    git -C "$ROOT" diff --stat -- $(echo "$changed") >&2 || true
    echo "Nothing was reverted. Inspect with 'git diff' and decide." >&2
    [ "$rc" -eq 0 ] && rc=3
  fi
  rm -f "$before" "$after"
  return $rc
}

ensure_test_db() {   # lab.sh reset drops the volumes; recreate chatwoot_test on demand
  $DC up -d postgres redis >/dev/null 2>&1
  $DC exec -T postgres psql -U postgres -tAc "select 1 from pg_database where datname='chatwoot_test'" 2>/dev/null | grep -q 1 \
    || $DC run --rm "${TEST_ENV[@]}" rails bundle exec rails db:create db:schema:load >/dev/null 2>&1
}

# Lab-only settings removed for hermetic spec runs so upstream specs see stock defaults.
SPEC_UNSET="DISABLE_TELEMETRY TERRANET_PRIVACY_MODE DISABLE_GRAVATAR MAILER_SENDER_EMAIL MAILER_INBOUND_EMAIL_DOMAIN SMTP_ADDRESS SMTP_DOMAIN SMTP_PORT SMTP_ENABLE_STARTTLS_AUTO"

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
             # db:migrate always re-dumps db/schema.rb (lib/tasks/db_enhancements.rake). Preparing the lab DB runs on a
             # disposable COPY mounted over db/schema.rb, so the tracked file is never touched. Schema changes made while
             # developing a migration go through `lab.sh rails db:migrate` (no copy) and show up in git as intended.
             SCHEMA_COPY=$(mktemp); cp "$ROOT/db/schema.rb" "$SCHEMA_COPY"
             with_tree_check $DC run --rm -v "$SCHEMA_COPY:/app/db/schema.rb" rails bundle exec rails db:chatwoot_prepare
             cmp -s "$SCHEMA_COPY" "$ROOT/db/schema.rb" || echo "info: the dump Rails would have written differs from db/schema.rb ($(diff "$SCHEMA_COPY" "$ROOT/db/schema.rb" | grep -c '^[<>]') lines, formatting/version normalization); tracked file left untouched"
             rm -f "$SCHEMA_COPY"
             # GlobalConfigService persists env-provided configs (e.g. DISABLE_GRAVATAR) into installation_configs on first read;
             # warm it once so concurrent first reads in Sidekiq don't race on the unique index (harmless but noisy retries).
             $DC run --rm rails bundle exec rails runner 'GlobalConfigService.load("DISABLE_GRAVATAR", "")' >/dev/null 2>&1 || true
             $DC up -d rails sidekiq vite gateway;;
  seed)      with_tree_check $DC run --rm rails bundle exec rails db:seed;;   # not needed after `up` (prepare seeds a fresh DB)
  down)      $DC down;;
  reset)     $DC down -v;;                                    # destroys lab DB/Redis volumes only
  ps)        $DC ps;;
  logs)      shift; $DC logs --tail=100 "$@";;
  dns-log)   $DC logs --no-log-prefix dns-sink | grep -E 'query\[' || true;;   # FQDNs requested by the lab
  health)    curl -fsS "http://127.0.0.1:$(grep ^LAB_RAILS_PORT .env | cut -d= -f2)/api" ; echo;;
  rails)     shift; with_tree_check $DC run --rm rails bundle exec rails "$@";;
  test-db)   # separate DB + Redis index so specs never touch the lab dev data
             $DC run --rm "${TEST_ENV[@]}" rails bundle exec rails db:create db:schema:load;;
  # Specs run hermetically: the privacy/edition switches that .env sets for the running lab are removed so upstream
  # specs see stock behaviour (e.g. chatwoot_hub_spec expects telemetry on); Terranet specs set what they need via
  # with_modified_env. Community Edition (Camino B): spec/enterprise is excluded like upstream's FOSS workflow does.
  # Same specs with the production privacy switches ON: shows which upstream examples assume Chatwoot-hub/avatar behaviour.
  # Terranet's own regression specs (privacy mode, endpoint tripwire, avatar/onboarding/push guards)
  rspec-terranet) shift; "$0" rspec spec/lib/terranet spec/jobs/internal/check_new_versions_job_privacy_spec.rb spec/jobs/avatar/avatar_from_gravatar_job_privacy_spec.rb spec/jobs/avatar/avatar_from_favicon_job_privacy_spec.rb spec/controllers/installation/onboarding_controller_privacy_spec.rb spec/services/notification/push_notification_service_privacy_spec.rb "$@";;
  rspec-privacy) shift; ensure_test_db; $DC run --rm "${TEST_ENV[@]}" -e TERRANET_PRIVACY_MODE=true -e DISABLE_TELEMETRY=true -e DISABLE_GRAVATAR=1 rails bundle exec rspec --exclude-pattern "spec/enterprise/**/*_spec.rb" "$@";;
  rspec)     shift; ensure_test_db; $DC run --rm "${TEST_ENV[@]}" rails sh -c "unset $SPEC_UNSET; exec bundle exec rspec --exclude-pattern 'spec/enterprise/**/*_spec.rb' \"\$@\"" rspec "$@";;
  # Production-flow simulation with synthetic data and no real services: RAILS_ENV=production on a disposable DB
  # (chatwoot_prodsim, Redis index 6), routed through egress-sink. PASS = privacy run leaves no DNS query for
  # chatwoot/gravatar/google and no packet at the sink; the control run (privacy off) MUST be detected, otherwise the
  # detector is blind and the audit fails.
  audit-egress)
    AUDIT_ENV=(-e RAILS_ENV=production -e POSTGRES_DATABASE=chatwoot_prodsim -e POSTGRES_USERNAME=postgres -e REDIS_URL=redis://redis:6379/6 -e RAILS_LOG_TO_STDOUT=false)
    $DC up -d postgres redis dns-sink egress-sink >/dev/null
    $DC run --rm "${AUDIT_ENV[@]}" audit bundle exec rails db:create db:schema:load >/dev/null 2>&1 || true
    forbidden='chatwoot|gravatar|google'
    run_audit() { # $1=label  $2=on|off  (off = stock upstream env: privacy switches removed, not set to empty)
      local label=$1 mode=$2; shift 2; local since; since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      local cmd="exec bundle exec rails runner terranet/lab/scripts/privacy_audit.rb"
      [ "$mode" = off ] && cmd="unset TERRANET_PRIVACY_MODE DISABLE_GRAVATAR DISABLE_TELEMETRY; $cmd"
      echo "=== $label"
      $DC --profile audit run --rm "${AUDIT_ENV[@]}" "$@" audit sh -c "$cmd" 2>&1 | grep -E "^(env=|  ok|  err)"
      sleep 2
      DNS_HITS=$($DC logs --since "$since" --no-log-prefix dns-sink 2>/dev/null | grep -E "query\[(A|AAAA)\]" | grep -Ei "$forbidden" | sed 's/.*query\[[A-Z]*\] //;s/ from .*//' | sort | uniq -c || true)
      PKT_HITS=$($DC logs --since "$since" --no-log-prefix egress-sink 2>/dev/null | grep -E " IP " | sed -E 's/^[0-9.]+ IP ([0-9.]+)\.[0-9]+ > ([0-9.]+\.[0-9]+).*/\1 -> \2/' | sort | uniq -c || true)
      echo "--- DNS queries matching /$forbidden/:"; echo "${DNS_HITS:-  (none)}"
      echo "--- packets seen by egress-sink:"; echo "${PKT_HITS:-  (none)}"
    }
    run_audit "PRIVACY ON (production simulation)" on -e TERRANET_PRIVACY_MODE=true -e DISABLE_GRAVATAR=1 -e DISABLE_TELEMETRY=true -e ENABLE_PUSH_RELAY_SERVER=false
    ON_DNS=$DNS_HITS; ON_PKT=$PKT_HITS
    run_audit "CONTROL: privacy OFF (detector sanity check, + direct-IP probe)" off -e ENABLE_PUSH_RELAY_SERVER=true -e AUDIT_DIRECT_IP=1
    if [ -z "$DNS_HITS" ] || [ -z "$PKT_HITS" ]; then echo "AUDIT FAIL: control run was not detected (detector blind)"; exit 2; fi
    if [ -n "$ON_DNS" ] || [ -n "$ON_PKT" ]; then echo "AUDIT FAIL: privacy mode leaked traffic"; exit 1; fi
    echo "AUDIT PASS: no forbidden DNS queries and no packets with privacy ON; control run detected"
    ;;
  # Camino B hardening check: builds a throw-away copy of the working tree WITHOUT enterprise/ and spec/enterprise
  # (what upstream's FOSS workflow does) in a temp dir, mounts it over /app and runs the check there. The real checkout
  # is never modified. Needed because config/application.rb:49 adds enterprise/app/views to the view path even when
  # DISABLE_ENTERPRISE=true, so Enterprise mail views still render against a Community Account model.
  foss-check)
    shift   # optional rspec paths to run inside the stripped copy (test DB/Redis, hermetic env)
    FOSS=$(mktemp -d -p "${LAB_TMPDIR:-${TMPDIR:-/tmp}}")
    # containers run as root, so the copy holds root-owned files (tmp/, public/vite-test): remove it through Docker
    trap 'docker run --rm -v "$FOSS:/cleanup" alpine sh -c "rm -rf /cleanup/* /cleanup/.[!.]*" >/dev/null 2>&1; rmdir "$FOSS" 2>/dev/null' EXIT
    ( cd "$ROOT" && git ls-files -z --cached --others --exclude-standard | grep -zvE '^(enterprise|spec/enterprise)/' | xargs -0 -I{} cp --parents {} "$FOSS" )
    echo "copy without enterprise/: $(find "$FOSS" -type f | wc -l) files; enterprise dir present: $([ -d "$FOSS/enterprise" ] && echo yes || echo no)"
    $DC run --rm -v "$FOSS:/app" -e DISABLE_ENTERPRISE= rails sh -c 'unset DISABLE_ENTERPRISE; bundle exec rails runner "
      puts \"enterprise?=#{ChatwootApp.enterprise?.inspect} privacy=#{Terranet::Privacy.enabled?} plan=#{ChatwootHub.pricing_plan}\"
      u = User.first
      begin
        html = Devise::Mailer.confirmation_instructions(u, \"tok\").body.to_s
        puts \"confirmation email: RENDER OK (#{html.size} bytes)\"
      rescue => e
        puts \"confirmation email: RENDER FAILED #{e.class}: #{e.message[0,80]}\"
      end"' 2>&1 | grep -E "^(enterprise\?|confirmation|copy)|rror" | head
    if [ $# -gt 0 ]; then
      ensure_test_db
      $DC run --rm -v "$FOSS:/app" "${TEST_ENV[@]}" rails sh -c "unset DISABLE_ENTERPRISE $SPEC_UNSET; exec bundle exec rspec \"\$@\"" rspec "$@" 2>&1 | grep -E "examples,|^rspec " | cut -c1-200
    fi
    ;;
  vitest)    shift; $DC run --rm rails pnpm test "$@";;
  *) echo "usage: $0 {init|build|bootstrap|up|seed|down|reset|ps|logs|dns-log|health|rails|test-db|rspec|rspec-terranet|rspec-privacy|audit-egress|foss-check|vitest}";;
esac
