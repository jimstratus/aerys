# Workflow import — bash wrapper around workflow_import.py.
#
# Python is the right tool here: the import engine needs JSON
# manipulation, two-pass reference rewriting, and HTTP retries that
# would be painful in pure bash.

import_workflows() {
  local api_key="$1"
  local env_path="$2"
  local deploy_dir="${3:-.}"
  local n8n_url="${4:-http://localhost:5678}"

  if [ -z "$api_key" ]; then
    log_error "import_workflows requires an n8n API key"
    return 1
  fi

  local workflows_dir="${INSTALLER_DIR}/workflows"
  if [ ! -d "$workflows_dir" ]; then
    log_error "Workflows directory not found: ${workflows_dir}"
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    log_error "python3 is required for workflow import (run ./aerys check to verify prereqs)"
    return 1
  fi

  log_section "Importing workflows into n8n at ${n8n_url}"

  python3 "${LIB_DIR}/workflow_import.py" \
    --workflows-dir "$workflows_dir" \
    --env-path "$env_path" \
    --n8n-url "$n8n_url" \
    --api-key "$api_key"
}

# Convenience: dry-run mode for testing without contacting n8n.
import_workflows_dry_run() {
  local env_path="$1"
  local workflows_dir="${INSTALLER_DIR}/workflows"

  python3 "${LIB_DIR}/workflow_import.py" \
    --workflows-dir "$workflows_dir" \
    --env-path "$env_path" \
    --api-key "dry-run-not-used" \
    --dry-run
}
