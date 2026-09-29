# Database initialization — handles bundled and external Postgres paths.
#
# Bundled path:
#   Copies migrations to deploy_dir/migrations/. Postgres's
#   /docker-entrypoint-initdb.d/ volume mount runs them on first
#   container start. No runtime action needed — just make sure the
#   files are in place before `docker compose up -d`.
#
# External path:
#   Calls db_init.py (psql-based) to connect, check idempotency,
#   run migrations, and verify schema.

_copy_migrations_to_deploy() {
  local deploy_dir="$1"
  local src_dir="${INSTALLER_DIR}/migrations"
  local dest_dir="${deploy_dir}/migrations"

  if [ ! -d "$src_dir" ]; then
    log_error "Installer migrations directory missing: ${src_dir}"
    return 1
  fi

  mkdir -p "$dest_dir"
  local count=0
  for f in "$src_dir"/*.sql; do
    [ -e "$f" ] || continue
    cp "$f" "$dest_dir/"
    count=$((count + 1))
  done
  log_success "Copied ${count} migration(s) to ${dest_dir}/"
}

init_database() {
  local env_path="$1"
  local deploy_dir="${2:-.}"

  if [ ! -f "$env_path" ]; then
    log_error ".env not found at ${env_path}"
    return 1
  fi

  # Load env into scope
  # shellcheck disable=SC1090
  set -a
  source "$env_path"
  set +a

  local bundled="${POSTGRES_BUNDLED:-true}"

  log_section "Database initialization"

  # Always stage migrations into deploy_dir — even on external path we
  # leave them there as reference artifacts.
  _copy_migrations_to_deploy "$deploy_dir" || return 1

  if [ "$bundled" = "true" ]; then
    log_info "Bundled Postgres detected."
    log_info "Migrations will auto-run when the container starts (docker-entrypoint-initdb.d)."
    log_info "To trigger now: (cd ${deploy_dir} && docker compose up -d postgres)"
    log_info "To verify later: ./aerys verify-db --env-path ${env_path}"
    return 0
  fi

  # External path: run migrations via psql
  log_info "External Postgres detected: ${POSTGRES_HOST}:${POSTGRES_PORT} as ${POSTGRES_USER}"

  if ! command -v python3 >/dev/null 2>&1; then
    log_error "python3 is required for external Postgres initialization"
    return 1
  fi

  if ! command -v psql >/dev/null 2>&1; then
    log_error "psql CLI not found. Install postgresql-client:"
    log_error "  Debian/Ubuntu: apt install postgresql-client"
    log_error "  Alpine:        apk add postgresql-client"
    log_error "  Fedora/RHEL:   dnf install postgresql"
    return 1
  fi

  PGPASSWORD="$POSTGRES_PASSWORD" python3 "${LIB_DIR}/db_init.py" \
    --migrations-dir "${INSTALLER_DIR}/migrations" \
    --host "$POSTGRES_HOST" \
    --port "$POSTGRES_PORT" \
    --user "$POSTGRES_USER"
}

verify_database() {
  local env_path="$1"
  local deploy_dir="${2:-.}"

  if [ ! -f "$env_path" ]; then
    log_error ".env not found at ${env_path}"
    return 1
  fi

  # shellcheck disable=SC1090
  set -a
  source "$env_path"
  set +a

  local bundled="${POSTGRES_BUNDLED:-true}"

  log_section "Verifying database schema"

  if [ "$bundled" = "true" ]; then
    if ! command -v docker >/dev/null 2>&1; then
      log_error "docker not available to verify bundled Postgres"
      return 1
    fi
    if [ ! -f "${deploy_dir}/docker-compose.yml" ]; then
      log_error "No docker-compose.yml in ${deploy_dir} — run ./aerys install first (or pass --deploy-dir)"
      return 1
    fi
    (cd "$deploy_dir" && docker compose exec -T postgres psql -U "$POSTGRES_USER" -d aerys \
      -c "SELECT extname FROM pg_extension; SELECT table_name FROM information_schema.tables WHERE table_schema='public';") \
      || {
        log_error "Verification failed — stack may not be running yet (cd ${deploy_dir} && docker compose up -d)"
        return 1
      }
    log_success "Bundled Postgres: aerys DB reachable, schema present."
    return 0
  fi

  # External path: use db_init.py --verify-only
  if ! command -v python3 >/dev/null 2>&1 || ! command -v psql >/dev/null 2>&1; then
    log_error "psql + python3 required for external DB verification"
    return 1
  fi

  PGPASSWORD="$POSTGRES_PASSWORD" python3 "${LIB_DIR}/db_init.py" \
    --migrations-dir "${INSTALLER_DIR}/migrations" \
    --host "$POSTGRES_HOST" \
    --port "$POSTGRES_PORT" \
    --user "$POSTGRES_USER" \
    --verify-only
}
