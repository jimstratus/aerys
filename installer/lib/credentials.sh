# Credential wizard — interactive prompts for API keys, bot tokens, DB creds.
# Writes to .env file in the deployment directory.
#
# Sections:
#   1. LLM backend (OpenRouter — required)
#   2. Chat adapter (Discord and/or Telegram — at least one required)
#   3. Optional tools (Google AI, Tavily)
#   4. Database (bundled Postgres or external)
#
# Writes via write_env_file() which takes a target path; default is ./.env
# relative to the caller's CWD. File is chmod 600.

# All variables live in this associative array so write_env_file can
# iterate without re-plumbing every section.
declare -gA AERYS_ENV

# --- Existing-value loader + per-section choice helper -----------------
#
# When the wizard is re-run (./aerys credentials) against an existing
# .env, we load current values into AERYS_ENV so each section can offer
# keep / update / remove instead of forcing the user to re-enter
# everything and lose the keys they didn't want to touch.

_load_existing_env() {
  local env_path="$1"
  [ -f "$env_path" ] || return 0
  while IFS= read -r line; do
    # Skip comments and blanks
    case "$line" in
      ''|'#'*) continue ;;
    esac
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"
      # Strip surrounding single or double quotes if present
      val="${val#\'}"; val="${val%\'}"
      val="${val#\"}"; val="${val%\"}"
      AERYS_ENV[$key]="$val"
    fi
  done < "$env_path"
  log_info "Loaded existing values from ${env_path} (${#AERYS_ENV[@]} keys)."
}

# _existing_credential_choice LABEL CURRENT_MASKED [allow_remove=1]
# Prints the prompt for an already-configured section and echoes:
#   "keep"   — leave existing values alone
#   "update" — re-prompt for new values
#   "remove" — unset the credential (only if allow_remove=1)
_existing_credential_choice() {
  local label="$1"
  local current="$2"
  local allow_remove="${3:-1}"

  printf "%s is currently configured: %s\n" "$label" "$current"
  if [ "$allow_remove" -eq 1 ]; then
    printf "  [k]eep as-is  [u]pdate credentials  [r]emove %s\n" "$label"
  else
    printf "  [k]eep as-is  [u]pdate credentials\n"
  fi

  local choice
  while :; do
    printf "Choice [k]: "
    read -r choice
    choice="${choice:-k}"
    case "$choice" in
      k|K) echo "keep"; return ;;
      u|U) echo "update"; return ;;
      r|R)
        if [ "$allow_remove" -eq 1 ]; then
          echo "remove"
          return
        fi
        log_warn "Cannot remove a required credential."
        ;;
      *) log_warn "Invalid choice. Enter k, u, or r." ;;
    esac
  done
}

# --- Section banner -----------------------------------------------------

_section_banner() {
  local title="$1"
  local description="$2"
  printf "\n"
  printf "%s━━━ %s ━━━%s\n" "$AERYS_COLOR_BLUE" "$title" "$AERYS_COLOR_RESET"
  if [ -n "$description" ]; then
    printf "%s\n" "$description"
  fi
  printf "\n"
}

# --- Section 1: LLM backend (required) ---------------------------------

_section_llm() {
  _section_banner "LLM Backend" "Aerys uses OpenRouter to call Claude, GPT, and other models.
Sign up at https://openrouter.ai and generate an API key."

  if [ -n "${AERYS_ENV[OPENROUTER_API_KEY]:-}" ]; then
    local choice
    choice=$(_existing_credential_choice "OpenRouter key" "$(_mask "${AERYS_ENV[OPENROUTER_API_KEY]}")" 0)
    [ "$choice" = "keep" ] && return 0
  fi

  local key
  prompt_secret key "OpenRouter API key (sk-or-...)"
  AERYS_ENV[OPENROUTER_API_KEY]="$key"
}

# --- Section 2: Chat adapters (at least one required) ------------------

_section_discord() {
  _section_banner "Discord bot (optional)" "Guided setup:
  1. https://discord.com/developers/applications → New Application
  2. Bot tab → Reset Token → copy the bot token
  3. OAuth2 → URL Generator → scopes: bot, applications.commands
     → permissions: Send Messages, Read Message History, Use Slash Commands
  4. Invite the bot to your server with the generated URL
  5. Enable Developer Mode in Discord (User Settings → Advanced), then
     right-click your server to get the Guild ID"

  if [ -n "${AERYS_ENV[DISCORD_BOT_TOKEN]:-}" ]; then
    local choice
    choice=$(_existing_credential_choice "Discord" "token $(_mask "${AERYS_ENV[DISCORD_BOT_TOKEN]}")" 1)
    case "$choice" in
      keep) return 0 ;;
      remove)
        unset "AERYS_ENV[DISCORD_BOT_TOKEN]"
        unset "AERYS_ENV[DISCORD_APPLICATION_ID]"
        unset "AERYS_ENV[DISCORD_GUILD_ID]"
        unset "AERYS_ENV[AERYS_ADMIN_ROLE_ID]"
        log_info "Discord credentials removed from the pending .env."
        return 0
        ;;
      update) ;;  # fall through
    esac
  else
    if ! prompt_yn "Configure Discord bot now?" "y"; then
      return 0
    fi
  fi

  local token app_id guild_id role_id
  prompt_secret token "Discord bot token"
  AERYS_ENV[DISCORD_BOT_TOKEN]="$token"

  prompt_required app_id "Discord Application ID" "17-20 digit number" validate_discord_snowflake
  AERYS_ENV[DISCORD_APPLICATION_ID]="$app_id"

  prompt_required guild_id "Discord Guild (server) ID" "17-20 digit number" validate_discord_snowflake
  AERYS_ENV[DISCORD_GUILD_ID]="$guild_id"

  prompt_optional role_id "Aerys admin role ID (skip if everyone has access)" "17-20 digit number" validate_discord_snowflake
  [ -n "$role_id" ] && AERYS_ENV[AERYS_ADMIN_ROLE_ID]="$role_id"
}

_section_telegram() {
  _section_banner "Telegram bot (optional)" "Guided setup:
  1. Open Telegram and talk to @BotFather
  2. /newbot → follow prompts → copy the HTTP API token"

  if [ -n "${AERYS_ENV[TELEGRAM_BOT_TOKEN]:-}" ]; then
    local choice
    choice=$(_existing_credential_choice "Telegram" "token $(_mask "${AERYS_ENV[TELEGRAM_BOT_TOKEN]}")" 1)
    case "$choice" in
      keep) return 0 ;;
      remove)
        unset "AERYS_ENV[TELEGRAM_BOT_TOKEN]"
        log_info "Telegram credentials removed from the pending .env."
        return 0
        ;;
      update) ;;  # fall through
    esac
  else
    if ! prompt_yn "Configure Telegram bot now?" "n"; then
      return 0
    fi
  fi

  local token
  prompt_secret token "Telegram bot token"
  AERYS_ENV[TELEGRAM_BOT_TOKEN]="$token"
}

# --- Section 3: Optional tools -----------------------------------------

_section_google_ai() {
  _section_banner "Google AI (Gemini) — optional" "Used for the fast tier of the model router.
Get a key at https://aistudio.google.com/apikey"

  if [ -n "${AERYS_ENV[GOOGLE_AI_API_KEY]:-}" ]; then
    local choice
    choice=$(_existing_credential_choice "Google AI" "$(_mask "${AERYS_ENV[GOOGLE_AI_API_KEY]}")" 1)
    case "$choice" in
      keep) return 0 ;;
      remove)
        unset "AERYS_ENV[GOOGLE_AI_API_KEY]"
        log_info "Google AI credentials removed from the pending .env."
        return 0
        ;;
      update) ;;
    esac
  else
    if ! prompt_yn "Configure Google AI now?" "n"; then
      return 0
    fi
  fi

  local key
  prompt_secret key "Google AI (Gemini) API key"
  AERYS_ENV[GOOGLE_AI_API_KEY]="$key"
}

_section_tavily() {
  _section_banner "Tavily — optional" "Web search tool for Aerys's research agent.
Get a key at https://tavily.com (free tier available)."

  if [ -n "${AERYS_ENV[TAVILY_API_KEY]:-}" ]; then
    local choice
    choice=$(_existing_credential_choice "Tavily" "$(_mask "${AERYS_ENV[TAVILY_API_KEY]}")" 1)
    case "$choice" in
      keep) return 0 ;;
      remove)
        unset "AERYS_ENV[TAVILY_API_KEY]"
        log_info "Tavily credentials removed from the pending .env."
        return 0
        ;;
      update) ;;
    esac
  else
    if ! prompt_yn "Configure Tavily now?" "n"; then
      return 0
    fi
  fi

  local key
  prompt_secret key "Tavily API key"
  AERYS_ENV[TAVILY_API_KEY]="$key"
}

# --- Section 4: Database -----------------------------------------------

_section_database() {
  _section_banner "Database" "Aerys needs Postgres with pgvector.
Default: bundled Postgres container, generated password.
Advanced: point at an external Postgres host."

  if [ -n "${AERYS_ENV[POSTGRES_PASSWORD]:-}" ] && [ -n "${AERYS_ENV[POSTGRES_BUNDLED]:-}" ]; then
    local current
    if [ "${AERYS_ENV[POSTGRES_BUNDLED]}" = "true" ]; then
      current="bundled container, password set"
    else
      current="external host ${AERYS_ENV[POSTGRES_HOST]}:${AERYS_ENV[POSTGRES_PORT]}"
    fi
    local choice
    choice=$(_existing_credential_choice "Database" "$current" 0)
    [ "$choice" = "keep" ] && return 0
    log_warn "Updating database credentials. CAUTION: changing bundled<->external or"
    log_warn "regenerating the password requires rebuilding the data volume or migrating"
    log_warn "your existing data. Only update if you know what you're doing."
  fi

  AERYS_ENV[POSTGRES_DB]="aerys"

  if prompt_yn "Use an external Postgres host (instead of the bundled container)?" "n"; then
    local host port user password
    prompt_required host "Postgres host" "postgres.example.internal"
    prompt_required port "Postgres port" "5432"
    prompt_required user "Postgres user" "aerys"
    prompt_secret password "Postgres password"
    AERYS_ENV[POSTGRES_HOST]="$host"
    AERYS_ENV[POSTGRES_PORT]="$port"
    AERYS_ENV[POSTGRES_USER]="$user"
    AERYS_ENV[POSTGRES_PASSWORD]="$password"
    AERYS_ENV[POSTGRES_BUNDLED]="false"
  else
    AERYS_ENV[POSTGRES_HOST]="postgres"
    AERYS_ENV[POSTGRES_PORT]="5432"
    AERYS_ENV[POSTGRES_USER]="aerys"
    AERYS_ENV[POSTGRES_PASSWORD]="$(_generate_password)"
    AERYS_ENV[POSTGRES_BUNDLED]="true"
    log_info "Generated a random Postgres password for the bundled container."
  fi
}

_generate_password() {
  # 32 URL-safe chars, avoiding shell-meta that might trip compose substitution
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -d '+/=' | head -c 32
  else
    # Portable fallback: /dev/urandom → LC_ALL=C tr to filter
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32
  fi
}

# --- Section 5: Personality (AI name) ---------------------------------

_section_personality() {
  _section_banner "Personality" "Your AI gets a name (used in the system prompt and conversation log).
Default is 'Aerys'. You can rename anytime by editing config/soul.md and restarting."

  local default_name="${AERYS_ENV[AI_NAME]:-Aerys}"
  local name
  prompt_optional name "AI name" "$default_name"
  AERYS_ENV[AI_NAME]="${name:-$default_name}"
}

# --- Section 5: Review + write -----------------------------------------

_mask() {
  local val="$1"
  local len="${#val}"
  if [ "$len" -le 8 ]; then
    printf "%s" "********"
  else
    printf "%s…%s" "${val:0:4}" "${val: -4}"
  fi
}

_review_summary() {
  _section_banner "Review" "Values will be written to your .env (passwords/keys masked below)."

  local key val display
  for key in "${!AERYS_ENV[@]}"; do
    val="${AERYS_ENV[$key]}"
    case "$key" in
      *TOKEN*|*KEY*|*PASSWORD*) display="$(_mask "$val")" ;;
      *) display="$val" ;;
    esac
    printf "  %-30s = %s\n" "$key" "$display"
  done
  printf "\n"
}

# write_env_file PATH
#
# Serializes AERYS_ENV to KEY=VALUE lines. Values are single-quoted and
# internal single-quotes escaped via the bash idiom '\''.
write_env_file() {
  local target="${1:-.env}"

  # Ensure the parent directory exists. Users who pass --env-path to a
  # fresh deploy dir shouldn't need to pre-create it by hand.
  local target_dir
  target_dir="$(dirname "$target")"
  if [ ! -d "$target_dir" ]; then
    if ! mkdir -p "$target_dir"; then
      log_error "Cannot create directory for .env: ${target_dir}"
      return 1
    fi
  fi

  if [ -e "$target" ]; then
    log_info "${target} exists — will back up before writing the updated version."
    if ! prompt_yn "Proceed?" "y"; then
      log_error "Aborting — existing ${target} preserved."
      return 1
    fi
    # Preserve values the wizard doesn't collect but other commands write
    # (N8N_API_KEY, which upgrade-workflows/health persist after first
    # prompt). The wizard loads these into AERYS_ENV via _load_existing_env
    # so this is usually already set; the guard handles the edge case of
    # someone running the wizard against a .env the loader couldn't parse.
    local preserved_n8n_key
    preserved_n8n_key=$(grep -E "^N8N_API_KEY=" "$target" | head -1 | cut -d= -f2- | sed -E "s/^['\"]?//; s/['\"]?$//")
    if [ -n "$preserved_n8n_key" ] && [ -z "${AERYS_ENV[N8N_API_KEY]:-}" ]; then
      AERYS_ENV[N8N_API_KEY]="$preserved_n8n_key"
    fi
    mv "$target" "${target}.bak.$(date +%s)"
    log_info "Backed up previous .env to ${target}.bak.<timestamp>"
  fi

  local tmp
  tmp="$(mktemp)"
  {
    printf "# Aerys configuration — generated by installer on %s\n" "$(date)"
    printf "# See https://github.com/sira-fiinikkusu/Aerys-Resonant-Span for docs\n\n"
    local key val
    for key in "${!AERYS_ENV[@]}"; do
      val="${AERYS_ENV[$key]}"
      val="${val//\'/\'\\\'\'}"
      printf "%s='%s'\n" "$key" "$val"
    done
  } > "$tmp"

  # mv + chmod must both succeed, else the caller thinks .env is ready
  # when it actually isn't. Return non-zero on either failure so the
  # orchestrator halts instead of marching on to compose generation.
  if ! mv "$tmp" "$target"; then
    log_error "Failed to write .env to ${target}"
    rm -f "$tmp"
    return 1
  fi
  if ! chmod 600 "$target"; then
    log_error "Failed to chmod .env at ${target}"
    return 1
  fi
  log_success "Wrote ${target} (chmod 600)."
}

# --- Orchestrator -------------------------------------------------------

run_credential_wizard() {
  local env_target="${1:-.env}"

  # Load existing values so re-running the wizard (./aerys credentials)
  # shows "keep/update/remove" for configured sections instead of treating
  # each one as a fresh prompt. For first-time installs this is a no-op.
  _load_existing_env "$env_target"

  # `set -u` (nounset) trips on `${#assoc_arr[@]}` for empty associative
  # arrays in some bash versions even when the array is declared. Run the
  # length check in a subshell with nounset off to avoid the false trip.
  local existing_count
  existing_count=$(set +u; echo "${#AERYS_ENV[@]}")
  local banner_note
  if [ "${existing_count:-0}" -gt 0 ]; then
    banner_note="Found existing configuration in ${env_target}. Each section will let
you [k]eep, [u]pdate, or [r]emove its current values. Sections you
never configured will prompt you normally."
  else
    banner_note="We'll collect the API keys and tokens Aerys needs.
You can skip optional sections with Enter or 'n'."
  fi
  _section_banner "Credential wizard" "$banner_note"

  _section_llm
  _section_discord
  _section_telegram

  # At least one chat adapter required
  if [ -z "${AERYS_ENV[DISCORD_BOT_TOKEN]:-}" ] && [ -z "${AERYS_ENV[TELEGRAM_BOT_TOKEN]:-}" ]; then
    log_error "At least one chat adapter (Discord or Telegram) is required."
    if prompt_yn "Re-run chat-adapter section?" "y"; then
      _section_discord
      _section_telegram
      if [ -z "${AERYS_ENV[DISCORD_BOT_TOKEN]:-}" ] && [ -z "${AERYS_ENV[TELEGRAM_BOT_TOKEN]:-}" ]; then
        log_error "Still no chat adapter configured. Aborting."
        return 1
      fi
    else
      return 1
    fi
  fi

  _section_google_ai
  _section_tavily
  _section_database
  _section_personality

  _review_summary

  if ! prompt_yn "Write these values to ${env_target}?" "y"; then
    log_error "Aborted — no .env written."
    return 1
  fi

  write_env_file "$env_target"
  log_success "Credential wizard complete."
  return 0
}
