#!/usr/bin/env python3
"""
Aerys workflow import engine.

Imports the sanitized workflow JSONs from installer/workflows/ into a
fresh n8n instance, creating credentials, rewriting placeholder
references, and activating workflows in the correct sequence.

Sequence:
  1. Wait for n8n /healthz (poll)
  2. Create credentials from .env values, capture real n8n IDs
  3. Import all workflows in two passes:
     a. POST each workflow JSON, capture real n8n IDs
     b. Rewrite YOUR_*_CREDENTIAL_ID and YOUR_*_WORKFLOW_ID placeholders
        with real IDs, PUT updated workflow back
  4. Activate workflows:
     - Skip: register-commands (one-shot)
     - Activate-first: discord-dm-adapter (IPC race protection)
     - Sleep 8s
     - Activate everything else
     - Activate-last: discord-adapter (guild) — triggers IPC restart

Invocation:
  python3 workflow_import.py \\
    --workflows-dir /path/to/installer/workflows \\
    --env-path /path/to/.env \\
    --n8n-url http://localhost:5678 \\
    --api-key <KEY>

Exit codes:
  0 success | 1 health-check timeout | 2 credential creation failed
  3 workflow import failed | 4 activation failed
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# --- Credential definitions --------------------------------------------
# Maps env var prerequisites → n8n credential payload(s) to create.
#
# Each entry produces 1+ credentials. The placeholder name (e.g.
# YOUR_OPEN_ROUTER_CREDENTIAL_ID) maps to the resulting real n8n credential
# ID at the end. We use the cred_placeholder() function in compose.sh /
# sanitize.py — replicate the same naming here.

CREDENTIAL_DEFS = [
    # Postgres for Aerys app DB. n8n internal DB uses the same Postgres
    # but n8n manages that connection itself via DB_* env vars; this
    # credential is for the workflows that read/write aerys_* tables.
    #
    # sshTunnel + allowUnauthorizedCerts are explicit discriminator flags:
    # omitting them triggers the "then" branch of n8n's JSON Schema
    # if/then/else, which makes all SSH fields required → HTTP 400.
    {
        "placeholder": "YOUR_POSTGRES_CREDENTIAL_ID",
        "type": "postgres",
        "name": "Aerys DB (aerys)",
        "data_from_env": lambda env: {
            "host": env.get("POSTGRES_HOST", "postgres"),
            "port": int(env.get("POSTGRES_PORT", "5432")),
            "database": env.get("POSTGRES_DB", "aerys"),
            "user": env["POSTGRES_USER"],
            "password": env["POSTGRES_PASSWORD"],
            "ssl": "disable",
            "allowUnauthorizedCerts": False,
            "sshTunnel": False,
        },
        "required": True,
    },

    # OpenRouter via openRouterApi credential type (LangChain nodes use this).
    # Placeholder name matches workflow JSONs (YOUR_OPEN_ROUTER_*, with
    # the underscore — cosmetic convention from the original sanitizer).
    {
        "placeholder": "YOUR_OPEN_ROUTER_CREDENTIAL_ID",
        "type": "openRouterApi",
        "name": "OpenRouter (Aerys)",
        "data_from_env": lambda env: {
            "apiKey": env["OPENROUTER_API_KEY"],
        },
        "required": True,
    },

    # OpenRouter via httpHeaderAuth (used by HTTP Request tool nodes).
    {
        "placeholder": "YOUR_OPENROUTER_HEADER_AUTH_CREDENTIAL_ID",
        "type": "httpHeaderAuth",
        "name": "OpenRouter Header Auth",
        "data_from_env": lambda env: {
            "name": "Authorization",
            "value": f"Bearer {env['OPENROUTER_API_KEY']}",
        },
        "required": True,
    },

    # Discord bot — only created if user configured Discord during wizard.
    {
        "placeholder": "YOUR_DISCORD_BOT_CREDENTIAL_ID",
        "type": "discordBotApi",
        "name": "Discord Bot account",
        "data_from_env": lambda env: {
            "botToken": env["DISCORD_BOT_TOKEN"],
        },
        "required": False,
        "skip_if": lambda env: not env.get("DISCORD_BOT_TOKEN"),
    },

    # Discord Bot Token Header — httpHeaderAuth used by raw HTTP nodes
    # that call the Discord API (e.g. Send Typing Indicator). The Discord
    # REST API requires the "Bot " prefix (not "Bearer ").
    {
        "placeholder": "YOUR_DISCORD_HEADER_AUTH_CREDENTIAL_ID",
        "type": "httpHeaderAuth",
        "name": "Discord Bot Token Header",
        "data_from_env": lambda env: {
            "name": "Authorization",
            "value": f"Bot {env['DISCORD_BOT_TOKEN']}",
        },
        "required": False,
        "skip_if": lambda env: not env.get("DISCORD_BOT_TOKEN"),
    },

    # Discord Bot Trigger — katerlol community node credential type.
    # The correct n8n type name is `discordBotTriggerApi` (not discordBotTrigger).
    # Schema fields: clientId (Discord Application ID), token (bot token),
    # plus the shared allowedHttpRequestDomains discriminator.
    # Note: community-node credentials (discordBotTriggerApi, tavilyApi
    # below) are versioned separately from n8n core. Their schemas still
    # include the allowedHttpRequestDomains discriminator — we must pass
    # it, otherwise the "then" branch fires and allowedDomains becomes
    # required. This is the opposite of core n8n (which dropped the field).
    {
        "placeholder": "YOUR_DISCORD_BOT_TRIGGER_CREDENTIAL_ID",
        "type": "discordBotTriggerApi",
        "name": "Discord Bot Trigger",
        "data_from_env": lambda env: {
            "clientId": env["DISCORD_APPLICATION_ID"],
            "token": env["DISCORD_BOT_TOKEN"],
            "allowedHttpRequestDomains": "all",
        },
        "required": False,
        "skip_if": lambda env: not env.get("DISCORD_BOT_TOKEN"),
    },

    # Telegram — only if configured. No discriminators in schema.
    {
        "placeholder": "YOUR_TELEGRAM_CREDENTIAL_ID",
        "type": "telegramApi",
        "name": "Telegram account",
        "data_from_env": lambda env: {
            "accessToken": env["TELEGRAM_BOT_TOKEN"],
        },
        "required": False,
        "skip_if": lambda env: not env.get("TELEGRAM_BOT_TOKEN"),
    },

    # Google AI direct (Gemini fast tier).
    # host is REQUIRED per schema — Google's generative-language endpoint.
    # Placeholder uses the workflow-side convention YOUR_GOOGLE_PALM_CREDENTIAL_ID.
    {
        "placeholder": "YOUR_GOOGLE_PALM_CREDENTIAL_ID",
        "type": "googlePalmApi",
        "name": "Google Gemini(PaLM) Api account",
        "data_from_env": lambda env: {
            "host": "https://generativelanguage.googleapis.com",
            "apiKey": env["GOOGLE_AI_API_KEY"],
        },
        "required": False,
        "skip_if": lambda env: not env.get("GOOGLE_AI_API_KEY"),
    },

    # Google AI via httpHeaderAuth (used by raw HTTP nodes calling Gemini direct).
    {
        "placeholder": "YOUR_GOOGLE_AI_HEADER_AUTH_CREDENTIAL_ID",
        "type": "httpHeaderAuth",
        "name": "Google AI - Aerys",
        "data_from_env": lambda env: {
            "name": "x-goog-api-key",
            "value": env["GOOGLE_AI_API_KEY"],
        },
        "required": False,
        "skip_if": lambda env: not env.get("GOOGLE_AI_API_KEY"),
    },

    # Tavily community node credential. Community-versioned schema still
    # requires allowedHttpRequestDomains — see note on discordBotTriggerApi.
    # Placeholder matches workflow JSONs (YOUR_TAVILY_*, not YOUR_TAVILY_API_*).
    {
        "placeholder": "YOUR_TAVILY_CREDENTIAL_ID",
        "type": "tavilyApi",
        "name": "Tavily account",
        "data_from_env": lambda env: {
            "apiKey": env["TAVILY_API_KEY"],
            "allowedHttpRequestDomains": "all",
        },
        "required": False,
        "skip_if": lambda env: not env.get("TAVILY_API_KEY"),
    },

    # Tavily via httpHeaderAuth (used by HTTP Request tool nodes).
    {
        "placeholder": "YOUR_TAVILY_HEADER_AUTH_CREDENTIAL_ID",
        "type": "httpHeaderAuth",
        "name": "Tavily API",
        "data_from_env": lambda env: {
            "name": "Authorization",
            "value": f"Bearer {env['TAVILY_API_KEY']}",
        },
        "required": False,
        "skip_if": lambda env: not env.get("TAVILY_API_KEY"),
    },
]

# Workflow activation policy.
#
# Chat adapters depend on the core agent, which depends on tier-agent
# sub-workflows. Activating adapters first fails with "references workflow
# X which is not published". Activating everything all at once in filename
# order happens to get this right by coincidence (06-xx agents activate
# before 02-03 core-agent which activates before 02-0x adapters), but we
# don't want to rely on alphabetization.
#
# The IPC race on the katerlol Discord trigger also needs DM adapter to
# go before guild adapter. So the activation order is:
#
#   1. All non-adapter workflows (sub-workflows with only internal deps)
#   2. 02-03 core-agent (consumer of tier agents)
#   3. 03-03 Discord DM adapter — IPC phase 1 (references core-agent)
#   4. sleep 8s for katerlol IPC to settle
#   5. 02-02 Telegram adapter  (references core-agent)
#   6. 02-01 Discord guild adapter — IPC phase 3, last (triggers IPC reload)

ADAPTERS_DM_FIRST = "03-03-discord-dm-adapter"
ADAPTER_CORE_AGENT = "02-03-core-agent"
ADAPTERS_MIDDLE = ["02-02-telegram-adapter"]
ADAPTERS_GUILD_LAST = "02-01-discord-adapter"
TELEGRAM_ADAPTER_SLUG = "02-02-telegram-adapter"
SKIP_ACTIVATION = ["03-02-register-commands"]  # run-once command registration


def _should_defer_telegram(env: dict) -> bool:
    """Telegram's activation calls /setWebhook on the bot API, which requires
    the workflow's WEBHOOK_URL to be a public HTTPS endpoint. During fresh
    installs, WEBHOOK_URL is still localhost — activation would 400. Defer
    until the user runs ./aerys set-webhook https://... which handles the
    activation inline once the tunnel is live."""
    url = (env.get("WEBHOOK_URL") or "").strip().lower()
    if not url:
        return True
    if not url.startswith("https://"):
        return True
    if "localhost" in url or "127.0.0.1" in url or "0.0.0.0" in url:
        return True
    return False


# --- Env loader ---------------------------------------------------------

ENV_LINE_RE = re.compile(r"^([A-Z_][A-Z0-9_]*)=['\"]?(.*?)['\"]?\s*$")

def load_env(path: Path) -> dict:
    env = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = ENV_LINE_RE.match(line)
        if m:
            env[m.group(1)] = m.group(2)
    return env


# --- HTTP client wrapper ----------------------------------------------

class N8N:
    def __init__(self, base_url: str, api_key: str):
        self.base = base_url.rstrip("/")
        self.headers = {
            "X-N8N-API-KEY": api_key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    def _request(self, method: str, path: str, body=None, retries=3, retry_delay=2):
        url = f"{self.base}{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers=self.headers)
        last_err = None
        for attempt in range(retries):
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    raw = resp.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as e:
                if 500 <= e.code < 600 and attempt < retries - 1:
                    time.sleep(retry_delay)
                    last_err = e
                    continue
                msg = e.read().decode("utf-8", errors="replace") if e.fp else ""
                raise RuntimeError(f"{method} {path} failed: HTTP {e.code} — {msg}") from e
            except urllib.error.URLError as e:
                last_err = e
                if attempt < retries - 1:
                    time.sleep(retry_delay)
                    continue
                raise RuntimeError(f"{method} {path} failed: {e}") from e
        raise RuntimeError(f"{method} {path} failed after {retries} retries: {last_err}")

    def get(self, path):
        return self._request("GET", path)

    def post(self, path, body):
        return self._request("POST", path, body)

    def put(self, path, body):
        return self._request("PUT", path, body)


# --- Health check -------------------------------------------------------

def wait_for_n8n(base_url: str, timeout_s: int = 120) -> bool:
    deadline = time.time() + timeout_s
    url = f"{base_url.rstrip('/')}/healthz"
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                if resp.status == 200:
                    return True
        except (urllib.error.URLError, urllib.error.HTTPError):
            pass
        time.sleep(2)
    return False


# --- Credentials --------------------------------------------------------

def _list_existing_credentials(client: N8N) -> dict:
    """Returns name → id map for all existing credentials. Handles pagination."""
    out = {}
    cursor = None
    while True:
        path = "/api/v1/credentials?limit=250"
        if cursor:
            path += f"&cursor={cursor}"
        try:
            resp = client.get(path)
        except RuntimeError:
            # Endpoint returns 405 on some n8n versions — credentials list not
            # supported via public API. Fall back to "no existing creds" which
            # means we create fresh each time (non-idempotent but not broken).
            return {}
        for cred in resp.get("data", []):
            name = cred.get("name")
            if name and cred.get("id"):
                out[name] = cred["id"]
        cursor = resp.get("nextCursor")
        if not cursor:
            break
    return out


def create_credentials(client: N8N, env: dict) -> dict:
    """Returns mapping placeholder → real credential ID.
    Idempotent: if a credential with the same name already exists in n8n,
    reuse its ID instead of creating a duplicate. (The Public API does not
    expose the decrypted data, so we can't diff and update — we trust the
    user's existing credential as-is.)"""
    placeholder_to_id = {}
    existing = _list_existing_credentials(client)
    for cdef in CREDENTIAL_DEFS:
        if cdef.get("skip_if") and cdef["skip_if"](env):
            print(f"  - skip {cdef['placeholder']} (env not configured)")
            continue
        try:
            data = cdef["data_from_env"](env)
        except KeyError as e:
            if cdef.get("required"):
                raise SystemExit(
                    f"ERROR: required env var {e} missing for credential {cdef['placeholder']}"
                )
            print(f"  - skip {cdef['placeholder']} (missing env var {e})")
            continue

        # Idempotent: if a credential with this name already exists, reuse
        if cdef["name"] in existing:
            real_id = existing[cdef["name"]]
            placeholder_to_id[cdef["placeholder"]] = real_id
            print(f"  ↺ reuse {cdef['placeholder']:<50s} → {real_id}  ({cdef['name']!r})")
            continue

        payload = {"name": cdef["name"], "type": cdef["type"], "data": data}
        try:
            resp = client.post("/api/v1/credentials", payload)
            real_id = resp.get("id")
            if not real_id:
                raise RuntimeError(f"no id in response: {resp}")
            placeholder_to_id[cdef["placeholder"]] = real_id
            print(f"  ✓ {cdef['placeholder']:<50s} → {real_id}  (new)")
        except RuntimeError as e:
            if cdef.get("required"):
                raise
            print(f"  - skip {cdef['placeholder']} ({e})")
    return placeholder_to_id


# --- Workflow import ----------------------------------------------------

def collect_workflows(workflows_dir: Path) -> list:
    """Returns list of (slug, json_dict) sorted by filename."""
    out = []
    for path in sorted(workflows_dir.glob("*.json")):
        slug = path.stem
        try:
            data = json.loads(path.read_text())
        except json.JSONDecodeError as e:
            print(f"  ✗ {slug}: invalid JSON ({e})")
            continue
        out.append((slug, data))
    return out


# Whitelist of .env keys whose values get substituted into workflow JSON.
# Kept narrow on purpose — we only inject values that legitimately can't be
# expressed via n8n credentials (inline HTTP Authorization headers, tokens
# hardcoded in Code nodes for URL construction). Adding a new key to this
# set means reviewing the workflow JSONs for where the placeholder appears.
ENV_PLACEHOLDER_WHITELIST = {
    "TELEGRAM_BOT_TOKEN",
    "DISCORD_BOT_TOKEN",
}


def substitute_env_placeholders(wf: dict, env: dict) -> dict:
    """Replace {{KEY}} occurrences in the workflow JSON with values from .env
    for whitelisted keys. Used for secrets that can't go through n8n's
    credential-reference system (HTTP Authorization headers, tokens
    embedded in Code node bodies for URL construction, etc.).

    Public workflow JSONs ship with placeholder strings; the real value is
    injected per-install from the user's .env. No placeholder → no-op.
    """
    raw = json.dumps(wf)
    for key in ENV_PLACEHOLDER_WHITELIST:
        placeholder = "{{" + key + "}}"
        if placeholder not in raw:
            continue
        value = env.get(key)
        if not value:
            # Placeholder present but user didn't configure this — leave it
            # as-is. The workflow activation will fail later with a clear
            # error (bad token), which is better than silently replacing
            # with an empty string.
            continue
        # json.dumps escapes the value correctly for JSON string context.
        # Trim surrounding quotes so we splice the literal value into the
        # existing "..." in the JSON.
        escaped = json.dumps(value)[1:-1]
        raw = raw.replace(placeholder, escaped)
    return json.loads(raw)


def slug_to_placeholder(slug: str) -> str:
    """Mirror of compose-side slug_to_placeholder."""
    parts = slug.split("-", 2)
    name = parts[2] if len(parts) > 2 else slug
    return f"YOUR_{name.upper().replace('-', '_')}_WORKFLOW_ID"


# Settings keys that POST /workflows accepts in current n8n. Older exports
# may contain additional version-specific fields (binaryMode, availableInMCP,
# etc.) that newer n8n rejects as "additional properties". Filter to the
# safe subset — the engine will still work across versions.
SAFE_SETTINGS_KEYS = {
    "executionOrder",
    "callerPolicy",
    "errorWorkflow",
    "timezone",
    "executionTimeout",
    "saveExecutionProgress",
    "saveManualExecutions",
    "saveDataErrorExecution",
    "saveDataSuccessExecution",
}


def strip_for_create(wf: dict) -> dict:
    """Strip metadata that POST /workflows doesn't accept (will be regenerated by n8n)."""
    settings_in = wf.get("settings", {}) or {}
    settings_out = {k: v for k, v in settings_in.items() if k in SAFE_SETTINGS_KEYS}
    payload = {
        "name": wf.get("name"),
        "nodes": wf.get("nodes", []),
        "connections": wf.get("connections", {}),
        "settings": settings_out,
    }
    if "staticData" in wf and wf["staticData"]:
        payload["staticData"] = wf["staticData"]
    return payload


def _list_existing_workflows(client: N8N) -> dict:
    """Returns name → id map for all existing workflows. Handles pagination."""
    out = {}
    cursor = None
    while True:
        path = "/api/v1/workflows?limit=250"
        if cursor:
            path += f"&cursor={cursor}"
        resp = client.get(path)
        for wf in resp.get("data", []):
            name = wf.get("name")
            if name and wf.get("id"):
                # On duplicates (past non-idempotent runs), keep the oldest
                # one we see — we'll overwrite it in pass 1 and leave the
                # newer copies orphaned for the user to clean up.
                if name not in out:
                    out[name] = wf["id"]
        cursor = resp.get("nextCursor")
        if not cursor:
            break
    return out


def import_workflows_pass1(client: N8N, workflows: list) -> dict:
    """Returns mapping slug → real workflow ID.
    Idempotent: if a workflow with the same name already exists, PUT an
    update instead of POST-ing a duplicate. Activation state is preserved
    across updates (PUT doesn't change active flag)."""
    slug_to_id = {}
    existing = _list_existing_workflows(client)
    for slug, wf in workflows:
        payload = strip_for_create(wf)
        wf_name = payload.get("name")
        try:
            if wf_name and wf_name in existing:
                real_id = existing[wf_name]
                # PUT replaces nodes/connections/settings in place. We'll
                # rewrite placeholder references in pass 2 and PUT again,
                # so this first PUT is with pre-rewrite placeholders —
                # harmless, gets overwritten in pass 2.
                client.put(f"/api/v1/workflows/{real_id}", payload)
                slug_to_id[slug] = real_id
                print(f"  ↺ updated {slug:<33s} → {real_id}  ({wf_name!r})")
            else:
                resp = client.post("/api/v1/workflows", payload)
                real_id = resp.get("id")
                if not real_id:
                    raise RuntimeError(f"no id in response: {resp}")
                slug_to_id[slug] = real_id
                print(f"  ✓ created {slug:<33s} → {real_id}  (new)")
        except RuntimeError as e:
            print(f"  ✗ {slug}: {e}")
            raise
    return slug_to_id


def rewrite_references(wf: dict, slug_to_id: dict, cred_to_id: dict) -> dict:
    """Walk workflow JSON, replace YOUR_*_CREDENTIAL_ID and YOUR_*_WORKFLOW_ID."""
    raw = json.dumps(wf)
    # Workflow refs
    for slug, real_id in slug_to_id.items():
        ph = slug_to_placeholder(slug)
        raw = raw.replace(ph, real_id)
    # Credential refs
    for ph, real_id in cred_to_id.items():
        raw = raw.replace(ph, real_id)
    return json.loads(raw)


def update_workflow(client: N8N, real_id: str, wf: dict) -> None:
    """PUT workflow back with rewritten references."""
    payload = strip_for_create(wf)
    client.put(f"/api/v1/workflows/{real_id}", payload)


# --- Activation ---------------------------------------------------------

def activate(client: N8N, real_id: str, slug: str, failures: list) -> None:
    """Best-effort activation: log failures, keep going. Installer is unblocked
    if one workflow's trigger fails (e.g. unrecognized community node). Caller
    inspects `failures` afterward to decide whether to warn or hard-fail.
    Idempotent: treats "already active" responses as success."""
    try:
        client.post(f"/api/v1/workflows/{real_id}/activate", {})
        print(f"  ✓ activated {slug:<35s} ({real_id})")
    except RuntimeError as e:
        err_lower = str(e).lower()
        # Some n8n versions return 400 "already active" — treat as success
        if "already active" in err_lower:
            print(f"  ↺ already active {slug:<30s} ({real_id})")
            return
        print(f"  ✗ failed to activate {slug}: {e}")
        failures.append((slug, real_id, str(e)))


def activate_in_order(client: N8N, slug_to_id: dict, deferred: set = None) -> list:
    """Dep-aware activation: sub-workflows → core-agent → adapters (IPC-safe).
    Returns (slug, real_id, error) tuples for any workflow that failed.

    `deferred` is a set of slugs to skip with an informational message (no
    failure). Used for workflows whose activation depends on a runtime
    precondition the installer can't satisfy — e.g. Telegram adapter needs
    a public HTTPS WEBHOOK_URL set up via ./aerys set-webhook."""
    all_slugs = list(slug_to_id.keys())
    skip = set(SKIP_ACTIVATION)
    deferred = deferred or set()

    # Bucket the slugs by activation tier
    adapter_slugs = {ADAPTERS_DM_FIRST, ADAPTER_CORE_AGENT, ADAPTERS_GUILD_LAST, *ADAPTERS_MIDDLE}
    sub_workflows = [s for s in all_slugs if s not in adapter_slugs and s not in skip]

    failures = []

    # Phase 1: sub-workflows (order within this group doesn't matter —
    # only intra-sub-workflow deps, and n8n allows activation of leaves
    # before internal nodes within the same tier)
    print("  Phase 1: activate sub-workflows (consumed by adapters + core agent)")
    for s in sub_workflows:
        activate(client, slug_to_id[s], s, failures)

    # Phase 2: core agent (uses tier agents, output router, memory workflows)
    if ADAPTER_CORE_AGENT in slug_to_id:
        print("  Phase 2: activate core-agent (depends on phase-1 sub-workflows)")
        activate(client, slug_to_id[ADAPTER_CORE_AGENT], ADAPTER_CORE_AGENT, failures)

    # Phase 3: DM adapter first to initialize katerlol IPC
    if ADAPTERS_DM_FIRST in slug_to_id:
        print("  Phase 3: activate DM adapter (IPC init — must precede guild adapter)")
        activate(client, slug_to_id[ADAPTERS_DM_FIRST], ADAPTERS_DM_FIRST, failures)
        print("  Sleep 8s for Discord IPC to settle...")
        time.sleep(8)

    # Phase 4: Telegram + other middle adapters
    print("  Phase 4: activate non-Discord adapters")
    for s in ADAPTERS_MIDDLE:
        if s in slug_to_id:
            if s in deferred:
                print(f"  → deferred {s:<35s} (activate later: ./aerys set-webhook https://...)")
                continue
            activate(client, slug_to_id[s], s, failures)

    # Phase 5: guild adapter last (triggers katerlol IPC reload, re-registers both)
    if ADAPTERS_GUILD_LAST in slug_to_id:
        print("  Phase 5: activate Discord guild adapter (IPC reload — last)")
        activate(client, slug_to_id[ADAPTERS_GUILD_LAST], ADAPTERS_GUILD_LAST, failures)

    # Retry pass — if anything failed due to race with its deps,
    # a second try after all its deps are now-active often succeeds
    if failures:
        print(f"\n  Retry pass: re-attempting {len(failures)} activation(s) whose deps may now be live")
        retry_targets = list(failures)
        failures.clear()
        for slug, real_id, _err in retry_targets:
            activate(client, real_id, slug, failures)

    if skip:
        skip_in_install = [s for s in skip if s in slug_to_id]
        if skip_in_install:
            print(f"  Skipped activation (one-shot workflows): {', '.join(skip_in_install)}")

    return failures


# --- Main ---------------------------------------------------------------

def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Aerys workflow import engine")
    p.add_argument("--workflows-dir", required=True, type=Path)
    p.add_argument("--env-path", required=True, type=Path)
    p.add_argument("--n8n-url", default="http://localhost:5678")
    p.add_argument("--api-key", required=True)
    p.add_argument("--health-timeout", type=int, default=120)
    p.add_argument("--dry-run", action="store_true",
                   help="Validate workflow JSONs and credential definitions; do not contact n8n")
    args = p.parse_args(argv)

    if not args.workflows_dir.is_dir():
        print(f"ERROR: workflows dir not found: {args.workflows_dir}", file=sys.stderr)
        return 3

    if not args.env_path.is_file():
        print(f"ERROR: .env not found: {args.env_path}", file=sys.stderr)
        return 2

    env = load_env(args.env_path)
    workflows = collect_workflows(args.workflows_dir)
    print(f"Found {len(workflows)} workflows")

    # Inject per-user secrets that can't go through n8n's credential system
    # (HTTP Authorization headers, tokens embedded in Code node bodies).
    # Workflows ship with {{KEY}} placeholders; we splice in the real value
    # from .env here before the first POST. Whitelist-gated.
    workflows = [(slug, substitute_env_placeholders(wf, env)) for slug, wf in workflows]

    if args.dry_run:
        print("\n--- Dry run: credential plan ---")
        for cdef in CREDENTIAL_DEFS:
            if cdef.get("skip_if") and cdef["skip_if"](env):
                status = "skip (not configured)"
            elif cdef.get("required") and not all(env.get(k) for k in _required_keys_for(cdef)):
                status = "MISSING required env"
            else:
                status = "would create"
            print(f"  {cdef['name']:<40s} ({cdef['type']:<20s}) — {status}")
        print("\n--- Dry run: workflow import order ---")
        adapter_slugs = {ADAPTERS_DM_FIRST, ADAPTER_CORE_AGENT, ADAPTERS_GUILD_LAST, *ADAPTERS_MIDDLE}
        for slug, _ in workflows:
            if slug == ADAPTERS_DM_FIRST:
                tag = "ADAPTER: DM (IPC first)"
            elif slug == ADAPTER_CORE_AGENT:
                tag = "CORE-AGENT (after subs)"
            elif slug == ADAPTERS_GUILD_LAST:
                tag = "ADAPTER: guild (IPC last)"
            elif slug in ADAPTERS_MIDDLE:
                tag = "ADAPTER: middle"
            elif slug in SKIP_ACTIVATION:
                tag = "SKIP-ACTIVATION"
            else:
                tag = "sub-workflow"
            print(f"  {slug:<35s} {tag}")
        return 0

    print(f"\n--- Waiting for n8n at {args.n8n_url} (timeout {args.health_timeout}s) ---")
    if not wait_for_n8n(args.n8n_url, args.health_timeout):
        print(f"ERROR: n8n did not become healthy within {args.health_timeout}s", file=sys.stderr)
        return 1

    client = N8N(args.n8n_url, args.api_key)

    print("\n--- Creating credentials ---")
    try:
        cred_to_id = create_credentials(client, env)
    except SystemExit:
        raise
    except Exception as e:
        print(f"ERROR: credential creation failed: {e}", file=sys.stderr)
        return 2

    print(f"\n--- Importing {len(workflows)} workflows (pass 1: create) ---")
    try:
        slug_to_id = import_workflows_pass1(client, workflows)
    except RuntimeError as e:
        print(f"ERROR: workflow import failed: {e}", file=sys.stderr)
        return 3

    print("\n--- Rewriting references (pass 2: update) ---")
    for slug, wf in workflows:
        rewritten = rewrite_references(wf, slug_to_id, cred_to_id)
        try:
            update_workflow(client, slug_to_id[slug], rewritten)
            print(f"  ✓ rewrote refs in {slug}")
        except RuntimeError as e:
            print(f"  ✗ {slug}: {e}")
            return 3

    print("\n--- Activating workflows ---")
    deferred = set()
    if _should_defer_telegram(env) and TELEGRAM_ADAPTER_SLUG in slug_to_id:
        deferred.add(TELEGRAM_ADAPTER_SLUG)
        print(f"  Note: WEBHOOK_URL is not a public HTTPS endpoint — Telegram adapter")
        print(f"  activation deferred. After Cloudflare tunnel setup (POST-INSTALL section 5):")
        print(f"    ./aerys set-webhook https://your-tunnel.example.com")
        print(f"  will update the URL, restart the stack, and activate the Telegram adapter.")
    failures = activate_in_order(client, slug_to_id, deferred)

    print(f"\n✓ Imported {len(slug_to_id)} workflows, created {len(cred_to_id)} credentials")
    if failures:
        print(f"\n⚠  {len(failures)} workflow(s) failed to activate:")
        for slug, real_id, err in failures:
            # Trim long error bodies — users need the slug + short reason
            short = err if len(err) < 200 else err[:200] + "..."
            print(f"    - {slug} ({real_id}): {short}")
        # Classify common causes so the hint is useful, not misleading
        all_err_text = " ".join(err for _, _, err in failures).lower()
        print("\nLikely causes based on the errors above:")
        if "unauthorized" in all_err_text or "invalid token" in all_err_text:
            print("  - Invalid bot token: Discord or Telegram activation validates the")
            print("    token against the service. Check .env values match your real bot.")
        if "not published" in all_err_text or "unrecognized node" in all_err_text:
            print("  - Sub-workflow dep or community node missing — try re-running this")
            print("    command; the retry pass usually catches transient-dep cases.")
        print("Fix the underlying issue, then retry:")
        print("  ./aerys upgrade-workflows")
        return 4
    return 0


def _required_keys_for(cdef):
    """Best-effort introspection of which env keys a credential definition reads."""
    import inspect
    src = inspect.getsource(cdef["data_from_env"])
    return re.findall(r"env\[['\"](\w+)['\"]\]", src)


if __name__ == "__main__":
    sys.exit(main())
