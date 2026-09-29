# Prompt helpers — sourced by credentials.sh and any interactive flows.
#
# Each prompt function sets the named global variable via `printf -v` so
# callers can read the value without running the function in a subshell
# (which would lose stdin/tty).

# prompt_required VAR "Human description" "example-hint" [validator_fn]
#
# Loops until non-empty (and passing validator if provided).
prompt_required() {
  local var_name="$1"
  local description="$2"
  local example="${3:-}"
  local validator="${4:-}"
  local value=""

  while true; do
    if [ -n "$example" ]; then
      printf "  %s %s\n  %s> %s" \
        "$AERYS_COLOR_BOLD" "$description" "$AERYS_COLOR_RESET" \
        "(e.g. ${example}) "
    else
      printf "  %s %s%s\n  > " \
        "$AERYS_COLOR_BOLD" "$description" "$AERYS_COLOR_RESET"
    fi
    IFS= read -r value
    if [ -z "$value" ]; then
      log_warn "Required — please enter a value."
      continue
    fi
    if [ -n "$validator" ] && ! "$validator" "$value"; then
      continue
    fi
    break
  done
  printf -v "$var_name" "%s" "$value"
}

# prompt_optional VAR "Human description" "example-hint" [validator_fn]
#
# Accepts empty input (sets var to empty string).
prompt_optional() {
  local var_name="$1"
  local description="$2"
  local example="${3:-}"
  local validator="${4:-}"
  local value=""

  while true; do
    if [ -n "$example" ]; then
      printf "  %s %s%s\n  %s(optional — press Enter to skip)%s\n  > " \
        "$AERYS_COLOR_BOLD" "$description" "$AERYS_COLOR_RESET" \
        "$AERYS_COLOR_YELLOW" "$AERYS_COLOR_RESET"
    else
      printf "  %s %s%s  %s(optional)%s\n  > " \
        "$AERYS_COLOR_BOLD" "$description" "$AERYS_COLOR_RESET" \
        "$AERYS_COLOR_YELLOW" "$AERYS_COLOR_RESET"
    fi
    IFS= read -r value
    if [ -z "$value" ]; then
      break
    fi
    if [ -n "$validator" ] && ! "$validator" "$value"; then
      continue
    fi
    break
  done
  printf -v "$var_name" "%s" "$value"
}

# prompt_secret VAR "Human description"
#
# Same as prompt_required but suppresses echo so secrets don't end up
# on the terminal scrollback.
prompt_secret() {
  local var_name="$1"
  local description="$2"
  local value=""

  while true; do
    printf "  %s %s%s\n  %s(hidden input)%s\n  > " \
      "$AERYS_COLOR_BOLD" "$description" "$AERYS_COLOR_RESET" \
      "$AERYS_COLOR_YELLOW" "$AERYS_COLOR_RESET"
    IFS= read -rs value
    printf "\n"
    if [ -z "$value" ]; then
      log_warn "Required — please enter a value."
      continue
    fi
    break
  done
  printf -v "$var_name" "%s" "$value"
}

# prompt_yn "Question?" "y|n" (default)
#
# Returns 0 for yes, 1 for no.
prompt_yn() {
  local question="$1"
  local default="${2:-n}"
  local default_display reply

  if [ "$default" = "y" ]; then
    default_display="Y/n"
  else
    default_display="y/N"
  fi

  while true; do
    printf "  %s %s %s[%s]%s > " \
      "$AERYS_COLOR_BOLD" "$question" \
      "$AERYS_COLOR_YELLOW" "$default_display" "$AERYS_COLOR_RESET"
    IFS= read -r reply
    reply="${reply:-$default}"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) log_warn "Please answer y or n." ;;
    esac
  done
}

# --- Validators ---------------------------------------------------------

# validate_not_whitespace VALUE — true if value has non-whitespace content
validate_not_whitespace() {
  [[ "$1" =~ [^[:space:]] ]] && return 0
  log_warn "Value is empty or whitespace-only."
  return 1
}

# validate_min_length VALUE LENGTH — wrapper factory isn't ergonomic in bash,
# so we take min length via AERYS_MIN_LENGTH env var set by caller.
validate_min_length() {
  local value="$1"
  local min="${AERYS_MIN_LENGTH:-1}"
  if [ "${#value}" -lt "$min" ]; then
    log_warn "Value looks too short (${#value} chars, expected ≥ ${min})."
    return 1
  fi
  return 0
}

# validate_discord_snowflake VALUE — 17-20 digit numeric (Discord IDs)
validate_discord_snowflake() {
  if [[ "$1" =~ ^[0-9]{17,20}$ ]]; then
    return 0
  fi
  log_warn "Doesn't look like a Discord ID (expected 17-20 digit number)."
  return 1
}

# validate_api_key VALUE — looks like an API key (≥ 20 chars, no spaces)
validate_api_key() {
  if [ "${#1}" -lt 20 ]; then
    log_warn "Shorter than a typical API key (${#1} chars) — double-check the paste."
    return 1
  fi
  if [[ "$1" =~ [[:space:]] ]]; then
    log_warn "Contains whitespace — likely paste error."
    return 1
  fi
  return 0
}

# validate_url VALUE — http(s)://...
validate_url() {
  if [[ "$1" =~ ^https?:// ]]; then
    return 0
  fi
  log_warn "Should start with http:// or https://"
  return 1
}
