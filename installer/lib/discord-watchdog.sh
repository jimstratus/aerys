# Discord IPC watchdog — install/uninstall helpers for the user-systemd unit
# that re-applies the deactivate/reactivate sequence on every n8n start.
#
# The watchdog runs as a per-user systemd service (no sudo, no system-wide
# install). It survives reboots if the user has lingering enabled (loginctl
# enable-linger), and reactivates Discord adapters automatically on every
# docker container start event.

AERYS_WATCHDOG_UNIT="aerys-discord-watchdog.service"
AERYS_WATCHDOG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"

# _watchdog_install DEPLOY_DIR ENV_PATH
_watchdog_install() {
  local deploy_dir="$1"
  local env_path="$2"
  local watcher_src="${INSTALLER_DIR}/scripts/discord-adapter-watcher.sh"

  if [ ! -x "$watcher_src" ]; then
    log_error "Watcher script not found or not executable: ${watcher_src}"
    return 1
  fi

  # Absolutize env_path before embedding in the unit: systemd runs the
  # script with WD=/ so a relative ".env" resolves to "/.env" and the
  # API-key read silently fails. Anchor relative paths to deploy_dir.
  case "$env_path" in
    /*) ;;
    *)  env_path="$(cd "$deploy_dir" 2>/dev/null && pwd)/${env_path}" ;;
  esac

  if ! command -v systemctl >/dev/null 2>&1; then
    log_warn "systemctl not present — skipping Discord watchdog setup."
    log_warn "On non-systemd systems, run the watcher manually:"
    log_warn "  AERYS_ENV_PATH='${env_path}' ${watcher_src} &"
    return 0
  fi

  # Resolve container name from compose project (defaults to deploy dir basename)
  local container_name
  container_name="$(basename "$(cd "$deploy_dir" 2>/dev/null && pwd || echo "$deploy_dir")")-n8n-1"

  mkdir -p "$AERYS_WATCHDOG_DIR"
  local unit_path="${AERYS_WATCHDOG_DIR}/${AERYS_WATCHDOG_UNIT}"

  cat > "$unit_path" <<EOF
[Unit]
Description=Aerys Discord adapter IPC watchdog
After=docker.service
Wants=docker.service

[Service]
Type=simple
Environment=AERYS_ENV_PATH=${env_path}
Environment=AERYS_N8N_URL=http://localhost:5678
Environment=AERYS_CONTAINER=${container_name}
ExecStart=${watcher_src}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

  log_info "Installing Discord watchdog systemd unit at ${unit_path}..."
  systemctl --user daemon-reload
  systemctl --user enable "$AERYS_WATCHDOG_UNIT" 2>&1 | grep -v "Created symlink" || true
  if ! systemctl --user start "$AERYS_WATCHDOG_UNIT"; then
    log_warn "Failed to start ${AERYS_WATCHDOG_UNIT}. View logs: journalctl --user -u ${AERYS_WATCHDOG_UNIT}"
    return 1
  fi
  log_success "Discord watchdog installed + started."

  # Persist user systemd across logout (otherwise watchdog stops when user logs out)
  if command -v loginctl >/dev/null 2>&1; then
    if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
      log_info "Enabling user-linger so watchdog survives logout (may prompt for sudo password)..."
      sudo loginctl enable-linger "$USER" 2>&1 | tail -3 || {
        log_warn "Could not enable user-linger. Watchdog will stop on logout."
        log_warn "To enable later: sudo loginctl enable-linger \$USER"
      }
    fi
  fi
}

_watchdog_uninstall() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi
  local unit_path="${AERYS_WATCHDOG_DIR}/${AERYS_WATCHDOG_UNIT}"
  if [ ! -f "$unit_path" ] && ! systemctl --user is-enabled "$AERYS_WATCHDOG_UNIT" >/dev/null 2>&1; then
    return 0
  fi
  log_info "Removing Discord watchdog..."
  systemctl --user stop "$AERYS_WATCHDOG_UNIT" 2>/dev/null || true
  systemctl --user disable "$AERYS_WATCHDOG_UNIT" 2>/dev/null || true
  rm -f "$unit_path"
  systemctl --user daemon-reload
  log_info "Discord watchdog removed."
}

# Standalone subcommand handler — called from main() for `./aerys install-discord-watchdog`
cmd_install_discord_watchdog() {
  local deploy_dir="$1"
  local env_path="$2"
  if [ ! -f "$env_path" ]; then
    log_error ".env not found: ${env_path}"
    log_error "Run ./aerys install first."
    return 1
  fi
  _watchdog_install "$deploy_dir" "$env_path"
}

# Optional: installer prompts for opt-in during ./aerys install
offer_discord_watchdog() {
  local deploy_dir="$1"
  local env_path="$2"

  # Only offer if Discord is configured (DISCORD_BOT_TOKEN present)
  local has_discord
  has_discord=$(grep -E "^DISCORD_BOT_TOKEN=" "$env_path" 2>/dev/null | head -1 | cut -d= -f2- | sed -E "s/^['\"]?//; s/['\"]?$//")
  if [ -z "$has_discord" ]; then
    log_info "Discord not configured — skipping watchdog offer."
    return 0
  fi

  printf "\n"
  log_section "Discord IPC watchdog (recommended)"
  log_info "n8n's katerlol IPC has a known race: after any container restart,"
  log_info "only ONE of your Discord adapters (DM or guild) actually listens."
  log_info "The watchdog re-applies the deactivate/reactivate sequence on every"
  log_info "n8n start event so both adapters stay live."

  if ! prompt_yn "Install Discord IPC watchdog (user systemd unit)?" "y"; then
    log_info "Skipped. Install later: ./aerys install-discord-watchdog"
    return 0
  fi

  _watchdog_install "$deploy_dir" "$env_path"
}
