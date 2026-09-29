# Prerequisite checks for the Aerys installer.
# Returns 0 if all required prereqs are satisfied; 1 otherwise.
# Side effect: prints per-check results via log_* helpers.

# Minimum disk space in gigabytes for a viable bundled Postgres + n8n install.
AERYS_MIN_DISK_GB=2

# Ports the installer will bind (defaults; Task 4 may change via config).
AERYS_PORT_N8N=5678
AERYS_PORT_POSTGRES=5432

_aerys_failed=0
_aerys_check_fail() {
  _aerys_failed=$((_aerys_failed + 1))
}

# --- OS / architecture ---------------------------------------------------

check_os() {
  local uname_s uname_m distro_id distro_ver
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"

  case "$uname_s" in
    Linux) ;;
    Darwin)
      log_warn "Running on macOS. Installer is Linux-first; your mileage may vary."
      ;;
    *)
      log_error "Unsupported OS: $uname_s (Linux or macOS only)"
      _aerys_check_fail
      return 0
      ;;
  esac

  case "$uname_m" in
    x86_64|amd64|aarch64|arm64) ;;
    *)
      log_warn "Unusual architecture: $uname_m — Docker images may not be available."
      ;;
  esac

  if [ "$uname_s" = "Linux" ] && [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    distro_id="$(. /etc/os-release && printf '%s' "${ID:-unknown}")"
    distro_ver="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
    log_success "OS: Linux ${distro_id} ${distro_ver} (${uname_m})"
  else
    log_success "OS: ${uname_s} (${uname_m})"
  fi
}

# --- Required binaries --------------------------------------------------

check_binary() {
  local name="$1"
  local hint="${2:-}"
  if command -v "$name" >/dev/null 2>&1; then
    log_success "${name}: $(command -v "$name")"
  else
    log_error "${name} not found${hint:+ — $hint}"
    _aerys_check_fail
  fi
}

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log_error "docker not found — install Docker Engine: https://docs.docker.com/engine/install/"
    _aerys_check_fail
    return 0
  fi

  if ! docker info >/dev/null 2>&1; then
    log_error "docker is installed but not accessible. Ensure the daemon is running and your user is in the docker group (or re-run with sudo)."
    _aerys_check_fail
    return 0
  fi

  log_success "docker: $(docker --version | head -1)"

  # Compose v2 plugin is strongly preferred. Accept v1 standalone as fallback.
  if docker compose version >/dev/null 2>&1; then
    log_success "docker compose: $(docker compose version --short 2>/dev/null || docker compose version | head -1)"
  elif command -v docker-compose >/dev/null 2>&1; then
    log_warn "docker-compose v1 standalone found. Installer prefers v2 plugin — continuing, but consider upgrading."
  else
    log_error "Neither 'docker compose' plugin nor 'docker-compose' standalone is installed."
    _aerys_check_fail
  fi
}

# --- Port availability --------------------------------------------------

check_port() {
  local port="$1"
  local label="$2"

  # If no port-listing tool is available, we can't check — warn and continue.
  if ! command -v ss >/dev/null 2>&1 \
    && ! command -v netstat >/dev/null 2>&1 \
    && ! command -v lsof >/dev/null 2>&1; then
    log_warn "Port ${port} (${label}): no ss/netstat/lsof available — skipping check"
    return 0
  fi

  local in_use=0
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "sport = :$port" 2>/dev/null | awk 'NR>1' | grep -q . && in_use=1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && in_use=1
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP -sTCP:LISTEN -P 2>/dev/null | awk '{print $9}' | grep -qE "[:.]${port}$" && in_use=1
  fi

  if [ "$in_use" -eq 1 ]; then
    log_error "Port ${port} (${label}) is already in use. Free it or change the port in config."
    _aerys_check_fail
  else
    log_success "Port ${port} (${label}) is free"
  fi
}

# --- Disk space ---------------------------------------------------------

check_disk() {
  local target="${1:-.}"
  local avail_gb

  if ! avail_gb="$(df -BG "$target" 2>/dev/null | awk 'NR==2 {sub(/G/, "", $4); print $4}')"; then
    log_warn "Could not determine disk space for ${target} — skipping check"
    return 0
  fi

  if [ -z "$avail_gb" ]; then
    log_warn "Could not parse disk space for ${target} — skipping check"
    return 0
  fi

  if [ "$avail_gb" -lt "$AERYS_MIN_DISK_GB" ]; then
    log_error "Available disk: ${avail_gb}G on ${target} — minimum ${AERYS_MIN_DISK_GB}G required"
    _aerys_check_fail
  else
    log_success "Disk: ${avail_gb}G available on ${target} (min ${AERYS_MIN_DISK_GB}G)"
  fi
}

# --- Orchestrator -------------------------------------------------------

check_prereqs() {
  log_section "Checking prerequisites"

  _aerys_failed=0

  check_os
  check_docker
  check_binary git "install via your package manager"
  check_binary curl "install via your package manager"
  check_binary jq "install via your package manager (used for workflow import)"
  check_binary python3 "install via your package manager (used for workflow import engine)"

  check_port "$AERYS_PORT_N8N" "n8n"
  check_port "$AERYS_PORT_POSTGRES" "postgres"

  check_disk "."

  if [ "$_aerys_failed" -gt 0 ]; then
    log_error "${_aerys_failed} prerequisite check(s) failed"
    return 1
  fi

  log_success "All prerequisite checks passed"
  return 0
}
