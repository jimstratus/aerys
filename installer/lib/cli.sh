# CLI subcommand layer.
#
# Adds `aerys <verb>` dispatch on top of the existing flag-based entry point.
# `aerys install` → full install (default behaviour of install.sh with no flags)
# `aerys update`  → regenerate compose + config
# `aerys upgrade-workflows --api-key KEY` → --import-workflows
# `aerys health [--api-key KEY]` → --health-check
# `aerys check`          → --check-only
# `aerys credentials`    → --credentials-only
# `aerys compose`        → --compose-only
# `aerys config`         → --config-only
# `aerys init-db`        → --init-db
# `aerys verify-db`      → --verify-db
# `aerys uninstall`      → --uninstall (prompts)
# `aerys install-community-nodes` → --install-community-nodes
#
# Day-to-day verbs (NEW — not a wrapper over flags):
# `aerys start`    → docker compose up -d in the deploy dir
# `aerys stop`     → docker compose down
# `aerys restart`  → docker compose restart n8n
# `aerys watch`    → docker compose logs -f n8n
#
# Env-change verbs (NEW):
# `aerys rename NAME`       → update AI_NAME in .env + regen config
# `aerys set-webhook URL`   → update WEBHOOK_URL in .env + regen compose + restart
# `aerys register-telegram` → register bot webhook with Telegram from .env values
#
# Deploy dir + env path are persisted to $XDG_CONFIG_HOME/aerys/config (falls
# back to $HOME/.aerys/config) on successful install, so day-to-day verbs
# don't need the user to pass --deploy-dir every time.

# --- Config file persistence -------------------------------------------

aerys_config_file() {
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    echo "${XDG_CONFIG_HOME}/aerys/config"
  else
    echo "${HOME}/.aerys/config"
  fi
}

# Source the config file (DEPLOY_DIR, ENV_PATH) if present. No-op otherwise.
read_aerys_config() {
  local cfg
  cfg="$(aerys_config_file)"
  if [ -f "$cfg" ]; then
    # shellcheck source=/dev/null
    source "$cfg"
  fi
}

# Write DEPLOY_DIR + ENV_PATH to the config file.
write_aerys_config() {
  local deploy_dir="$1"
  local env_path="$2"
  local cfg
  cfg="$(aerys_config_file)"
  local dir
  dir="$(dirname "$cfg")"
  mkdir -p "$dir"
  {
    printf '# Aerys CLI config — written by the installer on %s\n' "$(date)"
    printf 'DEPLOY_DIR=%s\n' "$deploy_dir"
    printf 'ENV_PATH=%s\n' "$env_path"
  } > "$cfg"
  chmod 600 "$cfg"
}

# --- Day-to-day verbs --------------------------------------------------

_require_compose() {
  local deploy_dir="$1"
  if [ ! -f "${deploy_dir}/docker-compose.yml" ]; then
    log_error "No docker-compose.yml in ${deploy_dir}"
    log_error "Run: ./aerys install (or pass --deploy-dir PATH)"
    return 1
  fi
}

cmd_start() {
  local deploy_dir="$1"
  _require_compose "$deploy_dir" || return 1
  log_info "Starting Aerys stack (${deploy_dir})..."
  (cd "$deploy_dir" && docker compose up -d)
}

cmd_stop() {
  local deploy_dir="$1"
  _require_compose "$deploy_dir" || return 1
  log_info "Stopping Aerys stack (${deploy_dir})..."
  (cd "$deploy_dir" && docker compose down)
}

cmd_restart() {
  local deploy_dir="$1"
  _require_compose "$deploy_dir" || return 1
  log_info "Restarting n8n..."
  (cd "$deploy_dir" && docker compose restart n8n)
}

cmd_watch() {
  local deploy_dir="$1"
  _require_compose "$deploy_dir" || return 1
  log_info "Following n8n logs (Ctrl-C to exit)..."
  (cd "$deploy_dir" && docker compose logs -f n8n)
}

# --- Env-change verbs --------------------------------------------------

# Update or add a KEY='value' line in a .env file. Single-quote escape for
# values containing apostrophes.
_update_env_key() {
  local env_path="$1"
  local key="$2"
  local value="$3"
  if [ ! -f "$env_path" ]; then
    log_error ".env not found: $env_path"
    return 1
  fi
  # Escape single quotes in the value
  local escaped="${value//\'/\'\\\'\'}"
  if grep -qE "^${key}=" "$env_path"; then
    # Portable in-place sed (works on both GNU and BSD)
    sed -i.bak "s|^${key}=.*|${key}='${escaped}'|" "$env_path"
    rm -f "${env_path}.bak"
  else
    echo "${key}='${escaped}'" >> "$env_path"
  fi
  chmod 600 "$env_path"
}

cmd_rename() {
  local deploy_dir="$1"
  local env_path="$2"
  local new_name="$3"
  if [ -z "$new_name" ]; then
    log_error "Usage: aerys rename NEW_NAME"
    return 1
  fi
  log_info "Renaming AI to '${new_name}'..."
  _update_env_key "$env_path" "AI_NAME" "$new_name" || return 1
  if ! generate_configs "$env_path" "$deploy_dir"; then
    log_error "Config regen failed."
    return 1
  fi
  log_success "AI_NAME set to '${new_name}'. soul.md regenerated."
  log_info "Restart n8n to pick up the new name: ./aerys restart"
}

# Find a workflow's ID by name (case-insensitive substring match). Echoes
# the first matching ID, or empty string if none found.
_find_workflow_id_by_name() {
  local n8n_url="$1"
  local api_key="$2"
  local name_needle="$3"
  local n8n_url_esc="${n8n_url%/}"
  curl -sS -m 10 -H "X-N8N-API-KEY: ${api_key}" \
    "${n8n_url_esc}/api/v1/workflows?limit=250" 2>/dev/null \
    | python3 -c "
import sys, json
needle = '''$name_needle'''.lower()
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for wf in data.get('data', []):
    if needle in (wf.get('name') or '').lower():
        print(wf.get('id', ''))
        break
" 2>/dev/null
}

# Activate the Telegram adapter workflow if preconditions are met.
# Idempotent: 'already active' treated as success. Soft-fails (warn, don't
# abort) because this runs as a side effect of set-webhook, not the primary
# command.
_activate_telegram_adapter() {
  local env_path="$1"
  local n8n_url="$2"
  local public_webhook_url="$3"

  local telegram_token
  telegram_token=$(grep -E "^TELEGRAM_BOT_TOKEN=" "$env_path" | head -1 | cut -d= -f2- | sed -E "s/^['\"]?//; s/['\"]?$//")
  if [ -z "$telegram_token" ]; then
    log_info "No TELEGRAM_BOT_TOKEN in .env — skipping Telegram adapter activation."
    return 0
  fi

  # Read stored API key up front so we can poll with the real key and
  # short-circuit when it validates. If no key stored yet, skip cleanly.
  local stored
  stored=$(_read_env_n8n_api_key "$env_path")
  if [ -z "$stored" ]; then
    log_info "No stored n8n API key — skipping Telegram adapter activation."
    log_info "Run ./aerys upgrade-workflows to store the key and activate Telegram."
    return 0
  fi

  # Wait up to ~180s for n8n's Public API to come online after restart.
  # On Jetson/Tachyon with 20+ workflows re-activating on startup, this
  # can legitimately take 2+ min. Poll with the REAL stored key so we
  # short-circuit on 200 (key valid + API up) without a second round trip.
  #
  # Response interpretation:
  #   200              → API up + key valid. Proceed to activation.
  #   401/403          → API up but key genuinely rejected. Skip.
  #   000/502/503/504/"" → connect fail or proxy warming up. Keep waiting.
  #   other            → unexpected; break out rather than spin forever.
  log_info "Waiting for n8n Public API to come online (up to 3 min on slow boards)..."
  local tries=0
  local api_code="000"
  local max_tries=90  # 90 × 2s = 180s
  while [ "$tries" -lt "$max_tries" ]; do
    api_code=$(curl -sS -m 3 -o /dev/null -w "%{http_code}" \
      -H "X-N8N-API-KEY: ${stored}" \
      "${n8n_url%/}/api/v1/workflows?limit=1" 2>/dev/null || true)
    api_code="${api_code: -3}"
    case "$api_code" in
      200|401|403) break ;;
      000|502|503|504|"") ;;  # keep waiting
      *) break ;;
    esac
    tries=$((tries + 1))
    # Progress ping every ~20s so the user knows we're alive
    if [ $((tries % 10)) -eq 0 ]; then
      log_info "  still waiting... ($((tries * 2))s elapsed, last HTTP ${api_code:-none})"
    fi
    sleep 2
  done
  if [ "$tries" -ge "$max_tries" ]; then
    log_warn "n8n Public API did not come online in 180s (last HTTP ${api_code:-none})."
    log_warn "Skipping Telegram activation. Once n8n is up:"
    log_warn "  ./aerys upgrade-workflows   # will activate Telegram for you"
    return 0
  fi

  if [ "$api_code" = "401" ] || [ "$api_code" = "403" ]; then
    log_warn "Stored n8n API key rejected (HTTP ${api_code}) — skipping Telegram adapter activation."
    log_warn "Run ./aerys upgrade-workflows to refresh the key."
    return 0
  fi

  # Find + activate. Wrap find in a short retry loop: n8n's API goes
  # green before workflows are fully populated after a restart, so the
  # first lookup can return empty even though the workflow exists. Retry
  # a few times before giving up.
  local wf_id=""
  local find_tries=0
  while [ "$find_tries" -lt 8 ]; do
    wf_id=$(_find_workflow_id_by_name "$n8n_url" "$stored" "Telegram Adapter")
    if [ -n "$wf_id" ]; then
      break
    fi
    find_tries=$((find_tries + 1))
    sleep 3
  done
  if [ -z "$wf_id" ]; then
    log_warn "Telegram Adapter workflow not found after ~24s of retries —"
    log_warn "probably never imported. Run: ./aerys upgrade-workflows"
    return 0
  fi

  local act_code
  act_code=$(curl -sS -m 10 -o /dev/null -w "%{http_code}" \
    -X POST -H "X-N8N-API-KEY: ${stored}" \
    "${n8n_url%/}/api/v1/workflows/${wf_id}/activate" 2>/dev/null || true)
  act_code="${act_code: -3}"

  # Verify actual state via GET — trusting POST's HTTP code is unreliable
  # because n8n's IPC reload + pgvector activation can block the event
  # loop long enough that the TCP connection drops before the response
  # arrives (curl reports 000) even though the activation succeeded.
  local is_active
  is_active=$(curl -sS -m 10 -H "X-N8N-API-KEY: ${stored}" \
    "${n8n_url%/}/api/v1/workflows/${wf_id}" 2>/dev/null \
    | python3 -c "import sys, json
try:
    d = json.load(sys.stdin)
    print('true' if d.get('active') else 'false')
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")

  if [ "$is_active" = "true" ]; then
    case "$act_code" in
      200|201|204|400)
        log_success "Telegram adapter activated (workflow ${wf_id})."
        ;;
      *)
        # Transient connection blip during a successful activation
        log_success "Telegram adapter activated (workflow ${wf_id}, POST returned ${act_code} but state confirms active)."
        ;;
    esac
  else
    log_warn "Telegram adapter activation verification returned '${is_active}' (POST HTTP ${act_code})."
    log_warn "Check the n8n UI; if not active, retry: ./aerys upgrade-workflows"
    return 0
  fi

  # Register the webhook with Telegram so the bot actually routes traffic
  # to our n8n endpoint. This is the same POST ./aerys register-telegram
  # makes — folding it in means set-webhook is one-stop.
  local target="${public_webhook_url%/}/webhook/telegram"
  local resp
  resp=$(curl -sS -m 10 -X POST "https://api.telegram.org/bot${telegram_token}/setWebhook" \
    -H "Content-Type: application/json" \
    -d "{\"url\":\"${target}\"}" 2>/dev/null || true)
  if printf '%s' "$resp" | grep -q '"ok":true'; then
    log_success "Telegram webhook registered with bot: ${target}"
  else
    log_warn "Telegram /setWebhook did not return ok. Response:"
    printf '%s\n' "$resp"
    log_warn "Retry standalone: ./aerys register-telegram"
  fi
}

cmd_set_webhook() {
  local deploy_dir="$1"
  local env_path="$2"
  local url="$3"
  if [ -z "$url" ]; then
    log_error "Usage: aerys set-webhook https://your-tunnel.example.com"
    return 1
  fi
  log_info "Setting WEBHOOK_URL to '${url}'..."
  _update_env_key "$env_path" "WEBHOOK_URL" "$url" || return 1
  if ! generate_docker_compose "$env_path" "$deploy_dir"; then
    log_error "Compose regen failed."
    return 1
  fi
  log_info "Bringing the stack up with the new webhook..."
  (cd "$deploy_dir" && docker compose up -d)
  log_success "Webhook URL updated; containers restarted."

  # If the new URL is HTTPS and Telegram is configured, activate the
  # Telegram adapter + register the webhook with Telegram. This is the
  # UX consolidation Chris asked for: no failure at upgrade-workflows
  # time, activation happens exactly once, at the moment it can succeed.
  if [[ "$url" =~ ^https:// ]]; then
    # WEBHOOK_URL is the public tunnel; n8n itself still listens on localhost.
    _activate_telegram_adapter "$env_path" "http://localhost:5678" "$url"
  else
    log_warn "URL is not HTTPS — Telegram adapter activation skipped."
    log_warn "Once you have a public HTTPS URL, re-run: ./aerys set-webhook https://..."
  fi
}

# --- n8n API key resolver ----------------------------------------------
#
# Resolves and validates the n8n API key. Priority:
#   1. Explicit --api-key flag → validate, persist to .env on success
#   2. N8N_API_KEY in .env     → validate; if rejected, prompt
#   3. Hidden prompt (up to 3 tries) → validate, persist to .env
#
# Lives next to OPENROUTER_API_KEY et al. in .env (chmod 600). Same threat
# model as every other secret in that file. If the key rotates in n8n, the
# 401 response triggers a re-prompt on the next run.
#
# On success, sets RESOLVED_N8N_API_KEY and returns 0. On failure returns 1.
# We use a global rather than stdout because log_info/log_success write to
# stdout, and capture via $() would pollute the key with log output.

RESOLVED_N8N_API_KEY=""

# 0 = good (200), 1 = bad key (401/403 or other 4xx/5xx), 2 = unreachable
_validate_n8n_api_key() {
  local n8n_url="$1"
  local key="$2"
  # curl emits "000" for connect failure / timeout; exit code is non-zero
  # but the template still prints. Keep only the last 3 digits to be
  # robust against curl emitting both "000" and a trailing echo fallback.
  local code
  code=$(curl -sS -m 10 -o /dev/null -w "%{http_code}" \
    -H "X-N8N-API-KEY: ${key}" \
    "${n8n_url%/}/api/v1/workflows?limit=1" 2>/dev/null || true)
  code="${code: -3}"
  case "$code" in
    200) return 0 ;;
    000|"") return 2 ;;
    *)   return 1 ;;
  esac
}

# Read N8N_API_KEY from .env (empty string if not set or file missing).
_read_env_n8n_api_key() {
  local env_path="$1"
  if [ -f "$env_path" ]; then
    grep -E "^N8N_API_KEY=" "$env_path" | head -1 | cut -d= -f2- | sed -E "s/^['\"]?//; s/['\"]?$//"
  fi
}

# Hidden prompt; echoes value on stdout. Prompt goes to stderr so stdout is
# clean for capture.
_prompt_n8n_api_key_hidden() {
  local prompt="${1:-n8n API key (hidden): }"
  local key=""
  printf '%s' "$prompt" >&2
  read -rs key
  printf '\n' >&2
  printf '%s' "$key"
}

resolve_n8n_api_key() {
  local env_path="$1"
  local n8n_url="$2"
  local explicit_key="${3:-}"

  RESOLVED_N8N_API_KEY=""

  # 1. Explicit flag — validate, persist on success
  if [ -n "$explicit_key" ]; then
    local rc=0
    _validate_n8n_api_key "$n8n_url" "$explicit_key" || rc=$?
    if [ "$rc" -eq 0 ]; then
      _update_env_key "$env_path" "N8N_API_KEY" "$explicit_key" 2>/dev/null || true
      RESOLVED_N8N_API_KEY="$explicit_key"
      return 0
    fi
    if [ "$rc" -eq 2 ]; then
      log_error "n8n unreachable at ${n8n_url} — start the stack first: ./aerys start"
      return 1
    fi
    log_error "The --api-key value was rejected by n8n (HTTP 401/403)."
    log_error "Get a fresh key from Settings → API in the n8n UI."
    return 1
  fi

  # 2. Stored key in .env
  local stored
  stored=$(_read_env_n8n_api_key "$env_path")
  if [ -n "$stored" ]; then
    local rc=0
    _validate_n8n_api_key "$n8n_url" "$stored" || rc=$?
    if [ "$rc" -eq 0 ]; then
      RESOLVED_N8N_API_KEY="$stored"
      return 0
    fi
    if [ "$rc" -eq 2 ]; then
      log_error "n8n unreachable at ${n8n_url} — start the stack first: ./aerys start"
      return 1
    fi
    log_warn "Stored N8N_API_KEY failed validation (rotated or revoked)."
  fi

  # 3. Hidden prompt — up to 3 tries
  log_info "Paste an n8n API key (create one at ${n8n_url%/} → Settings → API)."
  log_info "The key will be saved to ${env_path} (chmod 600) so future runs don't re-prompt."
  local tries=0
  while [ "$tries" -lt 3 ]; do
    local entered
    entered=$(_prompt_n8n_api_key_hidden "n8n API key (hidden, paste + Enter): ")
    if [ -z "$entered" ]; then
      log_error "No key entered — aborting."
      return 1
    fi
    local rc=0
    _validate_n8n_api_key "$n8n_url" "$entered" || rc=$?
    if [ "$rc" -eq 0 ]; then
      if _update_env_key "$env_path" "N8N_API_KEY" "$entered"; then
        log_success "Key validated and saved to ${env_path}."
      else
        log_warn "Could not persist key to ${env_path} — continuing with this run only."
      fi
      RESOLVED_N8N_API_KEY="$entered"
      return 0
    fi
    if [ "$rc" -eq 2 ]; then
      log_error "n8n unreachable at ${n8n_url} — start the stack first: ./aerys start"
      return 1
    fi
    tries=$((tries + 1))
    if [ "$tries" -lt 3 ]; then
      log_error "Key rejected by n8n (HTTP 401/403). Try again ($((3 - tries)) attempts left)."
    fi
  done
  log_error "Too many invalid attempts. Aborting."
  return 1
}

cmd_register_telegram() {
  local env_path="$1"
  if [ ! -f "$env_path" ]; then
    log_error ".env not found: $env_path"
    return 1
  fi
  local token url
  token=$(grep -E "^TELEGRAM_BOT_TOKEN=" "$env_path" | head -1 | cut -d= -f2- | sed -E "s/^['\"]?//; s/['\"]?$//")
  url=$(grep -E "^WEBHOOK_URL=" "$env_path" | head -1 | cut -d= -f2- | sed -E "s/^['\"]?//; s/['\"]?$//")
  if [ -z "$token" ]; then
    log_error "TELEGRAM_BOT_TOKEN not set in .env. Re-run ./aerys credentials to add it."
    return 1
  fi
  if [ -z "$url" ]; then
    log_error "WEBHOOK_URL not set in .env. Run: ./aerys set-webhook https://..."
    return 1
  fi
  local base="${url%/}"
  local target="${base}/webhook/telegram"
  log_info "Registering Telegram webhook with bot..."
  log_info "  URL: ${target}"
  local resp
  resp=$(curl -sS -X POST "https://api.telegram.org/bot${token}/setWebhook" \
    -H "Content-Type: application/json" \
    -d "{\"url\":\"${target}\"}")
  if echo "$resp" | grep -q '"ok":true'; then
    log_success "Telegram webhook registered."
    echo "$resp"
  else
    log_error "Telegram returned an error:"
    echo "$resp"
    return 1
  fi
}

# --- Subcommand dispatcher ---------------------------------------------
#
# Called from main() before flag parsing. If $1 is a recognized subcommand,
# handles it (often by setting the equivalent flag variables, then returning
# and letting main()'s flag-based logic run). Returns 0 on handled, 1 on
# "not a subcommand — let flag parser take over".
#
# For NEW verbs (start/stop/restart/watch/rename/set-webhook/register-telegram)
# the function exits directly rather than returning.

aerys_usage() {
  cat <<EOF
Aerys — personal AI companion on n8n + LangChain

Usage:
  aerys <command> [options]

Setup:
  install               Run the full installer (prereqs → wizard → compose →
                        DB → configs; prints next-steps for owner setup + import)
  check                 Verify prerequisites (Docker, ports, disk), do nothing else
  credentials           Re-run the credential wizard (writes .env only)
  compose               Regenerate docker-compose.yml from .env
  config                Regenerate soul.md + models.json + config.json
  init-db               Stage + run database migrations
  verify-db             Verify the Aerys schema is present
  install-community-nodes  Install required community packages into running n8n
  install-discord-watchdog Install user systemd unit that fixes the Discord IPC
                        race on every n8n restart (recommended if you use both
                        DM and guild Discord adapters)
  upgrade-workflows [--api-key KEY]
                        Install community nodes + import 23 workflows + activate.
                        On first run, prompts for the n8n API key (hidden input)
                        and stores it in .env (chmod 600) for future runs.
  health [--api-key KEY]   End-to-end health check. Uses the n8n API key stored
                        in .env when no --api-key flag is passed.
  update                Regenerate compose + config (for post-git-pull refresh)

Day-to-day:
  start                 docker compose up -d
  stop                  docker compose down
  restart               docker compose restart n8n
  watch                 Follow n8n logs (Ctrl-C to exit)

Env changes:
  rename NEW_NAME       Update AI_NAME in .env + regenerate soul.md
  set-webhook URL       Update WEBHOOK_URL + regenerate compose + restart
  register-telegram     POST to Telegram's setWebhook with your bot token

Teardown:
  uninstall             Tear down containers + data + configs (prompts)

Global options:
  --deploy-dir PATH     Override the persisted deploy dir
  --env-path PATH       Override the persisted .env path
  --api-key KEY         n8n API key (Settings → API in the n8n UI)
  --n8n-url URL         n8n base URL (default http://localhost:5678)
  --yes                 Skip interactive prompts (pairs with uninstall)
  --help                Show this help

First-time install:
  ./aerys install       The wizard collects credentials, writes .env, generates
                        docker-compose.yml + config/. After it completes, run:
                          ./aerys start
                          # owner setup + API key in the n8n UI
                          ./aerys upgrade-workflows   # prompts for API key, saves it

Backward-compat: install.sh (symlinked to aerys) accepts the old --foo flags.
EOF
}

# --- Shell integration (tab completion) ---------------------------------
#
# Offers to append a sentinel-marked line to the user's shell rc so `./aerys
# <tab>` autocompletes subcommands. Idempotent on re-run (checks for the
# sentinel). Removable on uninstall (same sentinel). Works for bash + zsh;
# detects shell via $SHELL, falls back to bash.

AERYS_SHELL_SENTINEL="# >>> aerys tab-completion >>>"
AERYS_SHELL_SENTINEL_END="# <<< aerys tab-completion <<<"

_detect_shell_rc() {
  case "${SHELL:-}" in
    */zsh) echo "${HOME}/.zshrc" ;;
    */fish) echo "" ;;  # fish uses a different completion system — skip
    *)     echo "${HOME}/.bashrc" ;;
  esac
}

_shell_integration_installed() {
  local rc="$1"
  [ -f "$rc" ] && grep -qF "$AERYS_SHELL_SENTINEL" "$rc"
}

offer_shell_integration() {
  local completion_path="${INSTALLER_DIR}/completions/aerys.bash"
  local rc
  rc=$(_detect_shell_rc)
  if [ -z "$rc" ]; then
    log_info "Your shell doesn't have a compatible bash-style completion — skipping."
    return 0
  fi
  if [ ! -f "$completion_path" ]; then
    log_warn "Completion file not found at ${completion_path} — skipping shell integration."
    return 0
  fi
  if _shell_integration_installed "$rc"; then
    log_info "Shell integration already present in ${rc}."
    return 0
  fi

  printf "\n"
  log_section "Shell integration (optional)"
  log_info "Enable tab completion for ./aerys subcommands?"
  log_info "Adds 3 lines (sentinel-marked, removed on uninstall) to: ${rc}"

  if ! prompt_yn "Enable tab completion?" "y"; then
    log_info "Skipped. You can enable later: echo 'source ${completion_path}' >> ${rc}"
    return 0
  fi

  {
    printf '\n%s\n' "$AERYS_SHELL_SENTINEL"
    printf 'source %s\n' "$completion_path"
    printf '%s\n' "$AERYS_SHELL_SENTINEL_END"
  } >> "$rc"
  log_success "Shell integration added to ${rc}."
  log_info "Reload your shell to activate: source ${rc}  (or open a new terminal)"
}

# Called by uninstall to remove the sentinel block. Safe to call if never
# installed (grep returns empty, sed is a no-op).
remove_shell_integration() {
  local rc
  rc=$(_detect_shell_rc)
  if [ -z "$rc" ] || [ ! -f "$rc" ]; then
    return 0
  fi
  if ! _shell_integration_installed "$rc"; then
    return 0
  fi
  # Delete from sentinel start through sentinel end, inclusive, plus the
  # optional leading blank line we added. Use a temp file rather than
  # sed -i.bak to be consistent with _update_env_key's portability.
  local tmp
  tmp="$(mktemp)"
  awk -v start="$AERYS_SHELL_SENTINEL" -v end="$AERYS_SHELL_SENTINEL_END" '
    BEGIN { skip = 0 }
    {
      if ($0 == start) { skip = 1; next }
      if (skip && $0 == end) { skip = 0; next }
      if (!skip) print
    }
  ' "$rc" > "$tmp" && mv "$tmp" "$rc"
  log_info "Removed aerys shell integration from ${rc}."
}

# Helper: called from main() after a successful full install, to persist
# paths to the CLI config file so day-to-day verbs can find them.
persist_install_paths() {
  local deploy_dir="$1"
  local env_path="$2"
  # Only write if these aren't "." / ".env" (defaults). If the user hasn't
  # specified a deploy_dir, they're running in CWD — write that absolute.
  local abs_deploy abs_env
  abs_deploy="$(cd "$deploy_dir" 2>/dev/null && pwd)" || abs_deploy="$deploy_dir"
  abs_env="$(cd "$(dirname "$env_path")" 2>/dev/null && pwd)/$(basename "$env_path")" || abs_env="$env_path"
  write_aerys_config "$abs_deploy" "$abs_env"
  log_info "Saved deploy dir to $(aerys_config_file) for future ./aerys commands."
}
