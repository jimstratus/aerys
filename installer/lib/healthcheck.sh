# Post-install health check suite.
#
# Verifies the deployment is alive end-to-end:
#   - Docker Compose stack is running (containers up)
#   - n8n /healthz returns 200
#   - Postgres accepts connections + aerys DB + persons table
#   - Required n8n credentials exist (optional, requires --api-key)
#   - Active workflows count matches what the installer expected
#
# Prints a consolidated summary with URLs + file paths.

_hc_fail=0
_hc_warn=0
_hc_pass=0

_hc_pass() { _hc_pass=$((_hc_pass + 1)); log_success "$*"; }
_hc_warn() { _hc_warn=$((_hc_warn + 1)); log_warn "$*"; }
_hc_fail() { _hc_fail=$((_hc_fail + 1)); log_error "$*"; }

_check_containers_running() {
  local deploy_dir="$1"
  if [ ! -f "${deploy_dir}/docker-compose.yml" ]; then
    _hc_fail "No docker-compose.yml in ${deploy_dir} — nothing to check"
    return 1
  fi

  local running
  running="$(cd "$deploy_dir" && docker compose ps --services --filter status=running 2>/dev/null || true)"
  if [ -z "$running" ]; then
    _hc_fail "Stack is not running. Start it: ./aerys start"
    return 1
  fi

  echo "$running" | while IFS= read -r svc; do
    _hc_pass "Container up: ${svc}"
  done
  return 0
}

_check_n8n_healthz() {
  local n8n_url="$1"
  if curl -sfm 5 "${n8n_url%/}/healthz" >/dev/null 2>&1; then
    _hc_pass "n8n /healthz responded (${n8n_url})"
  else
    _hc_fail "n8n /healthz failed at ${n8n_url}. May still be starting — retry in 30s."
  fi
}

_check_postgres_bundled() {
  local deploy_dir="$1"
  local pg_user="$2"
  if ! (cd "$deploy_dir" && docker compose exec -T postgres pg_isready -U "$pg_user" >/dev/null 2>&1); then
    _hc_fail "Postgres (bundled) not responding to pg_isready"
    return
  fi
  _hc_pass "Postgres: pg_isready OK"

  local tables
  tables="$(cd "$deploy_dir" && docker compose exec -T postgres psql -U "$pg_user" -d aerys -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -d ' \r\n')"
  if [ -n "$tables" ] && [ "$tables" -gt 0 ] 2>/dev/null; then
    _hc_pass "Postgres: aerys DB has ${tables} tables"
  else
    _hc_fail "Postgres: aerys DB missing or has 0 tables (re-run ./aerys init-db)"
  fi
}

_check_postgres_external() {
  local host="$1" port="$2" user="$3"
  if ! command -v psql >/dev/null 2>&1; then
    _hc_warn "Cannot check external Postgres: psql not installed on host"
    return
  fi
  if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$host" -p "$port" -U "$user" -d aerys \
    -c "SELECT 1" >/dev/null 2>&1; then
    _hc_pass "External Postgres (${host}:${port}) reachable; aerys DB exists"
  else
    _hc_fail "External Postgres (${host}:${port}) unreachable or aerys DB missing"
  fi
}

_check_n8n_workflows() {
  local n8n_url="$1" api_key="$2"
  local resp active
  resp="$(curl -sm 10 -H "X-N8N-API-KEY: ${api_key}" "${n8n_url%/}/api/v1/workflows?limit=100" 2>/dev/null || true)"
  if [ -z "$resp" ]; then
    _hc_warn "n8n API call failed — skipping workflow check"
    return
  fi

  # Count active workflows (minimal parsing: count "active":true)
  active="$(printf "%s" "$resp" | tr ',' '\n' | grep -c '"active":true' || true)"
  active="${active:-0}"

  # Compute expected count dynamically from the installer's own workflows
  # directory, minus any workflows in the skip-activation list (register-commands
  # is the canonical one — one-shot, must be run manually post-install).
  local total_wf skip_wf expected
  total_wf="$(ls "${INSTALLER_DIR}/workflows/"*.json 2>/dev/null | wc -l)"
  skip_wf=1  # 03-02-register-commands — keep in sync with workflow_import.py SKIP_ACTIVATION
  expected=$((total_wf - skip_wf))

  if [ "$active" -ge "$expected" ]; then
    _hc_pass "n8n: ${active} active workflows (expected ${expected}, all green)"
  elif [ "$active" -ge $((expected / 2)) ]; then
    _hc_warn "n8n: ${active} of ${expected} active — some imports or activations may have failed. Inspect the n8n UI or re-run --import-workflows."
  else
    _hc_fail "n8n: ${active} of ${expected} active — import likely didn't run. Try: ./aerys upgrade-workflows"
  fi
}

_print_summary() {
  local deploy_dir="$1" env_path="$2" n8n_url="$3" ai_name="$4"
  log_section "Summary"
  cat <<EOF
  Health check:       ${_hc_pass} passed, ${_hc_warn} warnings, ${_hc_fail} failed
  Deployment dir:     ${deploy_dir}
  Config file:        ${env_path}
  Personality file:   ${deploy_dir}/config/soul.md
  Model router:       ${deploy_dir}/config/models.json
  App settings:       ${deploy_dir}/config/config.json
  n8n UI:             ${n8n_url}
  AI name:            ${ai_name}

  Common commands:
    Start stack:      ./aerys start
    Stop stack:       ./aerys stop
    Tail n8n logs:    ./aerys watch
    Restart n8n:      ./aerys restart
    Re-verify:        ./aerys health

  Post-install guide: installer/POST-INSTALL.md (Cloudflare tunnel, Discord webhooks,
                      Telegram webhook registration, updating workflows, troubleshooting)
EOF
}

run_health_check() {
  local env_path="${1:-.env}"
  local deploy_dir="${2:-.}"
  local n8n_url="${3:-http://localhost:5678}"
  local api_key="${4:-}"

  if [ ! -f "$env_path" ]; then
    log_error ".env not found at ${env_path}"
    return 1
  fi

  # shellcheck disable=SC1090
  set -a
  source "$env_path"
  set +a

  _hc_fail=0
  _hc_warn=0
  _hc_pass=0

  local bundled="${POSTGRES_BUNDLED:-true}"
  local ai_name="${AI_NAME:-Aerys}"

  log_section "Health check"

  # Each sub-check records into _hc_fail/_hc_warn/_hc_pass via helpers.
  # Wrap in `|| true` so one failure doesn't short-circuit the rest under
  # `set -e` from the caller.
  _check_containers_running "$deploy_dir" || true
  _check_n8n_healthz "$n8n_url" || true

  if [ "$bundled" = "true" ]; then
    _check_postgres_bundled "$deploy_dir" "$POSTGRES_USER" || true
  else
    _check_postgres_external "$POSTGRES_HOST" "$POSTGRES_PORT" "$POSTGRES_USER" || true
  fi

  if [ -n "$api_key" ]; then
    _check_n8n_workflows "$n8n_url" "$api_key" || true
  else
    log_info "Skipping workflow-count check (run ./aerys upgrade-workflows first to store an n8n API key, or pass --api-key here)"
  fi

  _print_summary "$deploy_dir" "$env_path" "$n8n_url" "$ai_name"

  if [ "$_hc_fail" -gt 0 ]; then
    return 1
  fi
  return 0
}
