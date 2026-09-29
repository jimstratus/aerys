# Community-node bootstrap.
#
# Several Aerys workflows depend on third-party n8n community nodes:
#   - n8n-nodes-discord-trigger (katerlol)       — Discord guild + DM triggers
#   - @mazix/n8n-nodes-converter-documents       — DOCX → JSON conversion
#   - @tavily/n8n-nodes-tavily                   — Tavily web search tool
#
# These are npm packages. n8n's Docker image (Alpine) does not ship a
# Python toolchain, so naive `npm install` fails when a transitive dep
# (isolated-vm) tries to native-compile. Fortunately isolated-vm ships
# prebuilt binaries for linux-arm64 / linux-x64 / darwin-arm64 in its
# published tarball, so `npm install --ignore-scripts` skips the gyp
# step and the prebuilt .node file loads fine at runtime.
#
# This function runs inside the n8n container against the mounted nodes
# volume. Must be called AFTER `docker compose up -d` has brought n8n
# up at least once (volumes need to exist).

# Pinned package versions — match the versions running on the Tachyon
# reference deployment so behavior is reproducible.
readonly AERYS_COMMUNITY_PKGS=(
  "n8n-nodes-discord-trigger@0.8.0"
  "@mazix/n8n-nodes-converter-documents@1.2.2"
  "@tavily/n8n-nodes-tavily@0.5.1"
  "n8n-nodes-discord@0.5.0"
)

# Path to nodes dir on the HOST (relative to deploy_dir). This maps to
# /home/node/.n8n/nodes/ in the n8n container via the compose volume.
_nodes_host_dir() {
  echo "${1}/config/n8n/nodes"
}

# Build the package.json content as a bash heredoc producing valid JSON.
_write_nodes_package_json() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  {
    printf '{\n'
    printf '  "name": "installed-nodes",\n'
    printf '  "private": true,\n'
    printf '  "dependencies": {\n'
    local i=0
    local total="${#AERYS_COMMUNITY_PKGS[@]}"
    for spec in "${AERYS_COMMUNITY_PKGS[@]}"; do
      i=$((i + 1))
      local name="${spec%@*}"
      local version="${spec##*@}"
      # Handle @scoped packages where the first @ is part of the name
      if [[ "$spec" == @* ]]; then
        # @scope/name@version → name is everything before the LAST @
        name="${spec%@*}"
        version="${spec##*@}"
      fi
      local comma=","
      [ "$i" -eq "$total" ] && comma=""
      printf '    "%s": "%s"%s\n' "$name" "$version" "$comma"
    done
    printf '  }\n'
    printf '}\n'
  } > "$target"
}

# Install community nodes into a running n8n deployment.
#
# Arguments:
#   $1 — deploy_dir (dir containing docker-compose.yml)
#
# Behavior:
#   1. Checks the n8n container is running via `docker compose ps`.
#   2. Writes package.json to <deploy_dir>/config/n8n/nodes/
#      (bind-mounted into the container).
#   3. Runs `npm install --ignore-scripts --omit=dev` inside n8n.
#   4. Restarts the n8n container so the new nodes are loaded.
#   5. Polls /healthz until n8n is responsive (max 60s).
install_community_nodes() {
  local deploy_dir="${1:-.}"

  log_section "Installing n8n community nodes"

  # Verify compose file exists
  if [ ! -f "${deploy_dir}/docker-compose.yml" ]; then
    log_error "docker-compose.yml not found in ${deploy_dir} (run --compose-only first)"
    return 1
  fi

  # Verify n8n container is running
  if ! (cd "$deploy_dir" && docker compose ps --services --filter status=running 2>/dev/null | grep -q '^n8n$'); then
    log_error "n8n container is not running. Start it first:"
    log_error "  (cd ${deploy_dir} && docker compose up -d)"
    return 1
  fi

  # Write package.json to the nodes volume
  local pkg_json
  pkg_json="$(_nodes_host_dir "$deploy_dir")/package.json"
  _write_nodes_package_json "$pkg_json"
  log_info "Wrote package.json → ${pkg_json}"
  log_info "Packages to install:"
  for spec in "${AERYS_COMMUNITY_PKGS[@]}"; do
    log_info "  - ${spec}"
  done

  # Run npm install inside the container. Flags:
  #   --ignore-scripts : skip gyp postinstall (isolated-vm pulls in node-gyp
  #                      which needs Python, not in the n8n Alpine image;
  #                      prebuilts cover the platforms we run on)
  #   --omit=dev       : skip dev-dependencies at the transitive level
  #   --no-audit       : suppress the vulnerability report — noisy and
  #                      flagged issues live in community-package
  #                      transitive deps we can't fix from here
  #   --no-fund        : suppress "N packages are looking for funding"
  #   --loglevel=error : suppress `npm warn deprecated` spam from transitive
  #                      deps (e.g. inflight, glob@7 pulled in via
  #                      event-pubsub → copyfiles). These packages ship but
  #                      aren't required at runtime; they're vestigial build
  #                      tools misconfigured as runtime deps by upstream.
  #                      Errors still surface.
  log_info "Running npm install inside the n8n container (this takes 30-60s)..."
  log_info "Note: the install is quiet by design — npm warnings/audit output are"
  log_info "      suppressed because they flag transitive deps of community"
  log_info "      packages we can't fix from here and aren't actually loaded at"
  log_info "      runtime. Real errors still surface."
  if ! (cd "$deploy_dir" && docker compose exec -T --user node n8n \
        sh -c 'cd /home/node/.n8n/nodes && npm install --ignore-scripts --omit=dev --no-audit --no-fund --loglevel=error 2>&1 | tail -10'); then
    log_error "npm install failed inside the n8n container."
    log_error "Look above for the npm error output. Common causes:"
    log_error "  - Network/DNS issue reaching registry.npmjs.org"
    log_error "  - Disk full under ${deploy_dir}/config/n8n/"
    return 1
  fi
  log_success "Community packages installed."

  # Restart n8n to load the new node definitions
  log_info "Restarting n8n container to load community nodes..."
  if ! (cd "$deploy_dir" && docker compose restart n8n >/dev/null 2>&1); then
    log_error "docker compose restart n8n failed."
    return 1
  fi

  # Wait for n8n to be back up. /healthz turns green BEFORE the Public API
  # is ready — polling only /healthz causes a race where the next phase
  # hits /api/v1/credentials and gets a 404 "Cannot POST" (route not yet
  # registered). Wait for /api/v1 readiness specifically: an un-auth'd
  # GET returns 401 (JSON) once the Public API is up, vs. a 404 HTML
  # while it is still booting.
  local attempts=0
  local max_attempts=45
  local api_ready=0
  while [ "$attempts" -lt "$max_attempts" ]; do
    # First confirm healthz; then confirm the public-api plugin loaded
    if curl -sS --max-time 2 http://localhost:5678/healthz >/dev/null 2>&1; then
      # 401 = auth required (API up), 200 = unauthenticated (rare), 4xx JSON = up
      local api_check
      api_check=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 2 \
        http://localhost:5678/api/v1/workflows 2>/dev/null || echo "000")
      if [ "$api_check" = "401" ] || [ "$api_check" = "200" ]; then
        api_ready=1
        log_success "n8n is healthy and Public API ready ($((attempts * 2))s)."
        break
      fi
    fi
    attempts=$((attempts + 1))
    sleep 2
  done

  if [ "$api_ready" -eq 0 ]; then
    log_warn "n8n did not expose Public API within $((max_attempts * 2))s."
    log_warn "Check logs: (cd ${deploy_dir} && docker compose logs --tail=50 n8n)"
    return 1
  fi

  # Register packages in n8n's DB. Putting packages on disk is enough for
  # n8n to load them at runtime (the node palette + credential types work),
  # but Settings → Community Nodes in the UI reads from two tables:
  #   - installed_packages (one row per pkg)
  #   - installed_nodes    (one row per node type exposed by each pkg)
  # The UI's Install-via-click flow populates those tables. Our npm
  # bootstrap bypasses the UI so we populate them ourselves. Without this,
  # packages work but the UI shows "nothing installed" under Community
  # Nodes — confusing for users trying to manage/update packages later.
  _register_community_packages_in_db "$deploy_dir"
  return $?
}

# Insert/refresh rows in installed_packages + installed_nodes so the n8n
# UI lists our community packages under Settings → Community Nodes.
# Idempotent via ON CONFLICT DO NOTHING.
_register_community_packages_in_db() {
  local deploy_dir="${1:-.}"

  # Only bundled Postgres is supported today — the external-Postgres path
  # would need a separate psql invocation against the user's host and we
  # don't know their creds layout. External users get a warning + manual
  # instructions instead of a broken INSERT.
  local env_path="${deploy_dir}/.env"
  local bundled=""
  if [ -f "$env_path" ]; then
    bundled=$(grep -E "^POSTGRES_BUNDLED=" "$env_path" | cut -d= -f2 | tr -d "'\"")
  fi

  if [ "$bundled" != "true" ]; then
    log_warn "External Postgres detected — skipping installed_packages DB registration."
    log_warn "The community packages WORK (files are on disk) but the n8n UI's"
    log_warn "Settings → Community Nodes panel may not list them. To register"
    log_warn "manually, run this SQL against your n8n database:"
    log_warn "  see installer/lib/community_nodes.sh for the INSERT statements."
    return 0
  fi

  # n8n's DB user/db match our compose: DB_POSTGRESDB_DATABASE=n8n,
  # DB_POSTGRESDB_USER uses POSTGRES_USER from .env. The postgres service
  # is reachable via `docker compose exec postgres`.
  local pg_user
  pg_user=$(grep -E "^POSTGRES_USER=" "$env_path" | cut -d= -f2 | tr -d "'\"")
  pg_user="${pg_user:-aerys}"

  log_info "Registering community packages in n8n's UI database..."
  # Two inserts: first packages, then nodes. ON CONFLICT DO NOTHING makes
  # this idempotent so re-running --install-community-nodes is safe.
  if ! (cd "$deploy_dir" && docker compose exec -T postgres \
        psql -U "$pg_user" -d n8n -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
INSERT INTO installed_packages ("packageName", "installedVersion", "authorName") VALUES
  ('n8n-nodes-discord-trigger', '0.8.0', 'katerlol'),
  ('@mazix/n8n-nodes-converter-documents', '1.2.2', 'mazix'),
  ('@tavily/n8n-nodes-tavily', '0.5.1', 'Tavily AI'),
  ('n8n-nodes-discord', '0.5.0', 'hckdotng')
ON CONFLICT ("packageName") DO NOTHING;

INSERT INTO installed_nodes (name, type, "latestVersion", package) VALUES
  ('discordTrigger', 'n8n-nodes-discord-trigger.discordTrigger', 1, 'n8n-nodes-discord-trigger'),
  ('discordInteraction', 'n8n-nodes-discord-trigger.discordInteraction', 1, 'n8n-nodes-discord-trigger'),
  ('discordConfirm', 'n8n-nodes-discord-trigger.discordConfirm', 1, 'n8n-nodes-discord-trigger'),
  ('convertFileToJson', '@mazix/n8n-nodes-converter-documents.convertFileToJson', 1, '@mazix/n8n-nodes-converter-documents'),
  ('tavily', '@tavily/n8n-nodes-tavily.tavily', 1, '@tavily/n8n-nodes-tavily'),
  ('discord', 'n8n-nodes-discord.discord', 1, 'n8n-nodes-discord'),
  ('discordSend', 'n8n-nodes-discord.discordSend', 1, 'n8n-nodes-discord')
ON CONFLICT (name) DO NOTHING;
SQL
  ); then
    log_warn "Failed to register packages in n8n DB. Packages will still work,"
    log_warn "but may not appear in Settings → Community Nodes until re-added"
    log_warn "via the UI. To retry: ./aerys install-community-nodes"
    return 0  # Don't fail the install — functionally everything still works
  fi
  log_success "Packages registered in n8n UI database."
  return 0
}
