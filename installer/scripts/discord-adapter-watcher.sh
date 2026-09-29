#!/bin/bash
# Aerys Discord adapter IPC watchdog.
#
# Runs as a long-lived process. On startup AND on every n8n container restart,
# it re-applies the deactivate/reactivate sequence that katerlol's IPC needs to
# correctly register both Discord adapters (DM + guild). Without this, only one
# of the two adapters listens after any n8n restart — the other goes silent
# until the user manually fixes it in the n8n UI.
#
# IPC behaviour: all katerlol workflows share a single IPC process. Activating
# the guild adapter LAST triggers an IPC restart that re-registers every active
# katerlol workflow (DM + guild). Without the guild-last sequence, DM appears
# active in the n8n UI but doesn't actually receive events.
#
# Configuration: reads from .env (POSTGRES_BUNDLED, N8N_API_KEY, etc.). Discovers
# workflow IDs at runtime by name match, so it survives reinstalls + ID changes.
#
# Environment variables:
#   AERYS_ENV_PATH  — path to aerys .env (default: $DEPLOY_DIR/.env)
#   AERYS_N8N_URL   — n8n base URL (default: http://localhost:5678)
#   AERYS_CONTAINER — n8n container name (default: aerys-n8n-1)

set -u

AERYS_ENV_PATH="${AERYS_ENV_PATH:-${HOME}/aerys/.env}"
AERYS_N8N_URL="${AERYS_N8N_URL:-http://localhost:5678}"
AERYS_CONTAINER="${AERYS_CONTAINER:-aerys-n8n-1}"
MAX_WAIT=180
INTERVAL=5
POST_HEALTHZ_BUFFER=15

log() { echo "[aerys-watchdog] $*"; }

read_api_key() {
  if [ ! -f "$AERYS_ENV_PATH" ]; then
    return 1
  fi
  grep -E "^N8N_API_KEY=" "$AERYS_ENV_PATH" | head -1 \
    | cut -d= -f2- | sed -E "s/^['\"]?//; s/['\"]?$//"
}

# Look up a workflow ID by case-insensitive name match. Echoes ID or empty.
find_workflow_id() {
  local api_key="$1" name_needle="$2"
  curl -sS -m 10 -H "X-N8N-API-KEY: ${api_key}" \
    "${AERYS_N8N_URL%/}/api/v1/workflows?limit=250" 2>/dev/null \
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

api_post() {
  local api_key="$1" path="$2"
  curl -sS -m 10 -X POST -H "X-N8N-API-KEY: ${api_key}" \
    "${AERYS_N8N_URL%/}${path}" >/dev/null 2>&1
}

fix_adapters() {
  log "Waiting for n8n to be healthy..."
  local elapsed=0
  while [ "$elapsed" -lt "$MAX_WAIT" ]; do
    if curl -sf -m 5 "${AERYS_N8N_URL%/}/healthz" >/dev/null 2>&1; then
      log "n8n healthy after ${elapsed}s"
      break
    fi
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
  done
  if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    log "ERROR: n8n did not become healthy within ${MAX_WAIT}s" >&2
    return 1
  fi

  # Extra buffer so workflows finish loading after healthz turns green
  sleep "$POST_HEALTHZ_BUFFER"

  local api_key
  api_key="$(read_api_key)"
  if [ -z "$api_key" ]; then
    log "WARN: no N8N_API_KEY in ${AERYS_ENV_PATH} — skipping IPC fix."
    log "      run ./aerys upgrade-workflows once to populate it, then this watchdog will work."
    return 0
  fi

  local guild_id dm_id
  guild_id="$(find_workflow_id "$api_key" "Discord Adapter")"
  dm_id="$(find_workflow_id "$api_key" "Discord DM Adapter")"

  # Filter out the guild-adapter result if it accidentally matched the DM workflow's name
  if [ "$guild_id" = "$dm_id" ]; then
    guild_id=""
  fi

  if [ -z "$guild_id" ] && [ -z "$dm_id" ]; then
    log "Neither Discord adapter found — Discord likely not configured. Idle."
    return 0
  fi

  log "Resolved adapters: guild=${guild_id:-<not present>} dm=${dm_id:-<not present>}"
  log "Deactivating both adapters..."
  [ -n "$dm_id" ]    && api_post "$api_key" "/api/v1/workflows/${dm_id}/deactivate"
  [ -n "$guild_id" ] && api_post "$api_key" "/api/v1/workflows/${guild_id}/deactivate"
  sleep 3

  if [ -n "$dm_id" ]; then
    log "Activating DM adapter..."
    api_post "$api_key" "/api/v1/workflows/${dm_id}/activate"
    sleep 8
  fi

  if [ -n "$guild_id" ]; then
    log "Activating guild adapter (IPC restart re-registers both)..."
    api_post "$api_key" "/api/v1/workflows/${guild_id}/activate"
  fi

  log "Discord adapters reset complete."
}

# Fire immediately on watcher start — covers boot + service restarts
fix_adapters &

# Then watch for future n8n container restarts
docker events \
  --filter "container=${AERYS_CONTAINER}" \
  --filter 'event=start' \
  --format '{{.Status}}' | while read -r _status; do
  log "n8n container start detected, fixing adapters..."
  fix_adapters
done
