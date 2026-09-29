# Uninstall / teardown — stops containers, wipes data, removes generated
# files. Preserves the installer source (install.sh + lib/ + migrations/
# + config/ templates + README).

run_uninstall() {
  local deploy_dir="${1:-.}"
  local env_path="${2:-.env}"
  local yes_flag="${3:-0}"

  log_section "Uninstall Aerys"

  # Safety: refuse to tear down a directory that looks like an installer
  # checkout, not a deploy. If persisted config pointed at installer/ by
  # mistake (e.g. pre-symlink installs), the previous behavior was to
  # wipe `config/` and `migrations/` TEMPLATE directories shipped with
  # the installer. Detect by presence of the `aerys` script and `lib/`.
  if [ -x "${deploy_dir}/aerys" ] && [ -d "${deploy_dir}/lib" ] \
     && [ -d "${deploy_dir}/workflows" ] && [ -f "${deploy_dir}/README.md" ]; then
    log_error "Refusing to uninstall: '${deploy_dir}' looks like the installer checkout,"
    log_error "not a deploy. This would delete shipped templates, not your deployment."
    log_error ""
    log_error "If you meant to uninstall an aerys deploy, pass the deploy dir explicitly:"
    log_error "  ./aerys uninstall --deploy-dir /path/to/deploy"
    log_error ""
    log_error "If a prior install wrote a stale DEPLOY_DIR to ~/.config/aerys/config,"
    log_error "delete that file and orphan any leftover containers manually:"
    log_error "  rm -f ~/.config/aerys/config"
    log_error "  docker ps -a --format '{{.Names}}' | grep -E '^(aerys|installer)-' | xargs -r docker rm -f"
    return 2
  fi

  # Inventory what we're about to touch
  local compose_file="${deploy_dir}/docker-compose.yml"
  local data_dir="${deploy_dir}/data"
  local config_dir="${deploy_dir}/config"
  local migrations_dir="${deploy_dir}/migrations"
  local actual_env_path="$env_path"

  log_info "This will:"
  log_info "  1. Stop and remove the Docker containers (postgres + n8n)"
  log_info "  2. DELETE the Postgres data volume — ALL memories, identities, configs inside n8n"
  log_info "  3. Remove the generated files:"
  [ -f "$compose_file" ]   && log_info "       ${compose_file}"
  [ -d "$data_dir" ]       && log_info "       ${data_dir}/ (bind mount)"
  [ -d "$config_dir" ]     && log_info "       ${config_dir}/ (your soul.md will be lost — back up first if you edited it)"
  [ -d "$migrations_dir" ] && log_info "       ${migrations_dir}/"
  [ -f "$actual_env_path" ] && log_info "       ${actual_env_path} (your credentials + N8N_ENCRYPTION_KEY)"
  log_info ""
  log_info "Preserved: installer/ source directory, README.md, POST-INSTALL.md"
  log_info ""

  if [ "$yes_flag" -ne 1 ]; then
    if ! prompt_yn "Really proceed?" "n"; then
      log_info "Aborted. Nothing removed."
      return 0
    fi

    log_warn "Last chance — if you want to keep your memories, hit n now."
    if ! prompt_yn "Confirm destruction?" "n"; then
      log_info "Aborted. Nothing removed."
      return 0
    fi
  fi

  # Step 1: stop containers + remove volumes (for bundled Postgres)
  if [ -f "$compose_file" ]; then
    log_info "Stopping + removing containers..."
    (cd "$deploy_dir" && docker compose down -v 2>&1 | tail -5) || {
      log_warn "docker compose down -v returned non-zero — continuing anyway"
    }
  else
    log_info "No docker-compose.yml — skipping container teardown"
  fi

  # Step 2: wipe Postgres data dir (bind mount is root-owned due to
  # container init). Use a privileged container to delete contents we
  # can't touch as a regular user.
  if [ -d "$data_dir" ]; then
    log_info "Wiping data directory via privileged container..."
    if command -v docker >/dev/null 2>&1; then
      (cd "$deploy_dir" && docker run --rm -v "$(pwd)/data:/wipe" alpine sh -c 'rm -rf /wipe/*' 2>&1 | tail -3) || {
        log_warn "Privileged wipe failed — you may need sudo rm -rf ${data_dir}"
      }
    else
      log_warn "Docker not available to wipe root-owned ${data_dir} — run: sudo rm -rf ${data_dir}"
    fi
    rm -rf "$data_dir" 2>&1 || log_warn "Could not remove ${data_dir} — try again manually"
  fi

  # Step 3: remove generated files
  local removed=()
  if [ -f "$compose_file" ]; then
    rm -f "$compose_file"
    removed+=("$compose_file")
  fi
  if [ -d "$config_dir" ]; then
    rm -rf "$config_dir"
    removed+=("$config_dir")
  fi
  if [ -d "$migrations_dir" ]; then
    rm -rf "$migrations_dir"
    removed+=("$migrations_dir")
  fi
  if [ -f "$actual_env_path" ]; then
    rm -f "$actual_env_path"
    removed+=("$actual_env_path")
  fi

  # Step 4a: remove shell integration (tab-completion source line) from
  # the user's ~/.bashrc or ~/.zshrc. Defined in cli.sh. No-op if it was
  # never installed or the user opted out.
  if declare -f remove_shell_integration >/dev/null 2>&1; then
    remove_shell_integration
  fi

  # Step 4b: remove the Discord watchdog systemd unit if installed.
  # Defined in discord-watchdog.sh. No-op if never installed.
  if declare -f _watchdog_uninstall >/dev/null 2>&1; then
    _watchdog_uninstall
  fi

  # Step 4: remove the CLI persisted config so stale DEPLOY_DIR/ENV_PATH
  # paths don't leak into the next install. (The file lives at
  # $XDG_CONFIG_HOME/aerys/config or ~/.aerys/config — see cli.sh.)
  local cli_cfg
  if [ -n "${XDG_CONFIG_HOME:-}" ] && [ -f "${XDG_CONFIG_HOME}/aerys/config" ]; then
    cli_cfg="${XDG_CONFIG_HOME}/aerys/config"
  elif [ -f "${HOME}/.aerys/config" ]; then
    cli_cfg="${HOME}/.aerys/config"
  elif [ -f "${HOME}/.config/aerys/config" ]; then
    # Fallback when XDG_CONFIG_HOME is unset but the user has ~/.config/
    cli_cfg="${HOME}/.config/aerys/config"
  fi
  if [ -n "${cli_cfg:-}" ] && [ -f "$cli_cfg" ]; then
    rm -f "$cli_cfg"
    removed+=("$cli_cfg")
  fi

  log_section "Uninstall complete"
  log_success "Removed ${#removed[@]} path(s)"
  for p in "${removed[@]}"; do
    log_info "  - ${p}"
  done
  log_info ""
  log_info "The installer itself (aerys, lib/, migrations/, config/) is untouched."
  log_info "To re-install: ./aerys install"
  return 0
}
