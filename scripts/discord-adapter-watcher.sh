#!/bin/bash
# Discord Adapter IPC Race Fix — ensures both guild and DM adapters register correctly after n8n restart
#
# Persistent watcher — fixes katerlol Discord trigger IPC race on every n8n start.
# Fires on watcher start (boot/hardware restart) AND on every Docker container restart.
#
# IPC behaviour: all katerlol workflows share one IPC process. When guild adapter is
# deactivated+reactivated, the IPC restarts and n8n re-registers ALL active katerlol
# workflows (guild + DM adapter). Only guild needs explicit handling here — DM adapter
# picks up automatically as long as it stays active in the n8n DB.

N8N_URL="http://localhost:5678"
GUILD_ADAPTER_ID="YOUR_GUILD_ADAPTER_WORKFLOW_ID"
DM_ADAPTER_ID="YOUR_DM_ADAPTER_WORKFLOW_ID"
API_KEY="YOUR_N8N_API_KEY"
MAX_WAIT=180
INTERVAL=5

fix_adapter() {
    echo "[aerys] Waiting for n8n to be healthy..."
    local elapsed=0
    while [ $elapsed -lt $MAX_WAIT ]; do
        if curl -sf "$N8N_URL/healthz" > /dev/null 2>&1; then
            echo "[aerys] n8n healthy after ${elapsed}s"
            break
        fi
        sleep $INTERVAL
        elapsed=$((elapsed + INTERVAL))
    done

    if [ $elapsed -ge $MAX_WAIT ]; then
        echo "[aerys] ERROR: n8n did not become healthy within ${MAX_WAIT}s" >&2
        return 1
    fi

    # Extra buffer for workflows to fully load
    sleep 15

    # Deactivate both first — clean slate
    echo "[aerys] Deactivating both Discord adapters..."
    curl -sf -X POST "$N8N_URL/api/v1/workflows/$DM_ADAPTER_ID/deactivate" \
        -H "X-N8N-API-KEY: $API_KEY" > /dev/null
    curl -sf -X POST "$N8N_URL/api/v1/workflows/$GUILD_ADAPTER_ID/deactivate" \
        -H "X-N8N-API-KEY: $API_KEY" > /dev/null
    sleep 3

    # Activate DM first so it is in n8n's active registry
    echo "[aerys] Activating DM adapter..."
    curl -sf -X POST "$N8N_URL/api/v1/workflows/$DM_ADAPTER_ID/activate" \
        -H "X-N8N-API-KEY: $API_KEY" > /dev/null
    sleep 8

    # Activate guild last — this restarts the IPC process and n8n re-registers
    # ALL active katerlol workflows (both guild + DM). Confirmed by two
    # 'Connected to IPC server' lines appearing in n8n logs.
    echo "[aerys] Activating guild adapter (IPC restart re-registers both adapters)..."
    curl -sf -X POST "$N8N_URL/api/v1/workflows/$GUILD_ADAPTER_ID/activate" \
        -H "X-N8N-API-KEY: $API_KEY" > /dev/null
    echo "[aerys] Both Discord adapters active"
}

# Fire immediately on watcher start — covers boot and service restarts
fix_adapter &

# Then watch for future n8n container restarts
docker events \
    --filter 'container=aerys-n8n-1' \
    --filter 'event=start' \
    --format '{{.Action}}' | while read -r _status; do
    echo "[aerys] n8n container start detected, fixing adapter..."
    fix_adapter
done
