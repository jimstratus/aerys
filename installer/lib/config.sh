# Config setup — generates soul.md (personality), models.json (model tiering),
# config.json (app settings) in the deployment config directory.
#
# Prerequisites:
#   AI_NAME should be in the .env (wizard asks for it). If missing,
#   defaults to "Aerys".

_render_soul_md() {
  local template="$1"
  local target="$2"
  local ai_name="$3"

  # Bash parameter expansion handles the {{AI_NAME}} substitution without
  # pulling in sed -i portability issues (macOS vs GNU).
  local content
  content="$(cat "$template")"
  content="${content//\{\{AI_NAME\}\}/$ai_name}"
  printf "%s\n" "$content" > "$target"
}

generate_configs() {
  local env_path="${1:-.env}"
  local deploy_dir="${2:-.}"

  if [ ! -f "$env_path" ]; then
    log_error ".env not found at ${env_path}"
    return 1
  fi

  # shellcheck disable=SC1090
  set -a
  source "$env_path"
  set +a

  local ai_name="${AI_NAME:-Aerys}"
  local config_src="${INSTALLER_DIR}/config"
  local config_dest="${deploy_dir}/config"

  if [ ! -d "$config_src" ]; then
    log_error "Installer config source directory missing: ${config_src}"
    return 1
  fi

  mkdir -p "$config_dest"

  log_section "Config setup (AI name: ${ai_name})"

  # soul.md — personality with AI_NAME substitution
  local soul_target="${config_dest}/soul.md"
  if [ -e "$soul_target" ]; then
    mv "$soul_target" "${soul_target}.bak.$(date +%s)"
    log_info "Backed up existing soul.md → soul.md.bak.<timestamp>"
  fi
  _render_soul_md "${config_src}/soul.md.template" "$soul_target" "$ai_name"
  log_success "Wrote ${soul_target}"

  # models.json — copy as-is
  cp "${config_src}/models.json" "${config_dest}/models.json"
  log_success "Wrote ${config_dest}/models.json"

  # config.json — copy template (no substitutions needed for MVP)
  if [ ! -e "${config_dest}/config.json" ]; then
    cp "${config_src}/config.json.template" "${config_dest}/config.json"
    log_success "Wrote ${config_dest}/config.json (template — edit to add Discord notify channel)"
  else
    log_info "${config_dest}/config.json already exists — preserving user edits"
  fi

  log_info "Config customization:"
  log_info "  - Personality: ${soul_target}"
  log_info "  - Model tiering: ${config_dest}/models.json"
  log_info "  - App settings: ${config_dest}/config.json"
  log_info "Edits take effect immediately (n8n reads on each execution — no rebuild needed)"
}
