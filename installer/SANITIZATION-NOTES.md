# Sanitization Notes — installer/workflows/

Workflow JSONs in this directory are **sanitized exports of the live n8n Aerys instance**. Each JSON either uses generic placeholders (`YOUR_*`) for n8n-internal IDs and credentials, or `{{KEY}}` template slots that get filled in from the user's `.env` at install time (see "Env placeholder substitution" below).

Sanitizer: `/tmp/task1-sync/sanitize.py` (not versioned — rebuild from cruise-plan Task 1 context if needed).

## What was sanitized

| Field | Original | Placeholder |
|---|---|---|
| Workflow top-level `id` | real n8n UUID (e.g. `V67KVguBAJG1sOij`) | descriptive slug (e.g. `02-04-output-router`) |
| `versionId`, `activeVersionId`, `activeVersion.id`, `activeVersion.versionId`, `shared[].project.creatorId` | real UUIDs | `00000000-0000-0000-0000-000000000000` |
| `triggerCount` | live count | `0` |
| `shared[].workflowId` | real workflow UUID | `YOUR_<NAME>_WORKFLOW_ID` (per-workflow) |
| `shared[].projectId` | real project UUID | `YOUR_N8N_PROJECT_ID` |
| `shared[].project.name` | real project name | `"Your Project"` |
| `shared[].project` author email (`christopher.perry0887@gmail.com`) | real | stripped (no email in output) |
| `activeVersion.authors`, `activeVersion.workflowPublishHistory` | author metadata | `[]` |
| `settings.errorWorkflow` | real workflow ID | `YOUR_CENTRAL_ERROR_WORKFLOW_ID` |
| Node credential IDs (e.g. `1UB6LFvh3qKCfdbJ`) | real | `YOUR_<TYPE>_CREDENTIAL_ID` |
| Sub-workflow cross-references (executeWorkflow `workflowId.value`) | real UUIDs | `YOUR_<TARGET>_WORKFLOW_ID` |
| Bearer tokens (HA long-lived access token) | real JWT | `"Bearer YOUR_BEARER_TOKEN"` |
| Local network IPs (`192.168.1.157`, `192.168.1.155`, `192.168.1.231`) | real | `YOUR_AERYS_HOST_IP`, `YOUR_HA_HOST_IP`, `YOUR_NAS_HOST_IP` |
| Discord IDs (guild, app, owner DM channel, debug channel, echoes, admin role) | real | `YOUR_*` placeholders |
| Chris's person_id in DB (`6e6bcbed-03ef-4d17-95d2-89c467414335`) | real | `YOUR_OWNER_PERSON_ID` |
| Cloudflare tunnel + worker domains | real | `your-tunnel.example`, `your-cf-worker.example.workers.dev` |

## Env placeholder substitution

Some secrets can't go through n8n's credential-reference system because they appear as literal string values (HTTP Authorization headers, tokens embedded inside Code node bodies for URL construction). For those, the workflow JSONs ship with `{{KEY}}` placeholders that `workflow_import.py` substitutes from the user's `.env` at import time.

Whitelist (`ENV_PLACEHOLDER_WHITELIST` in `lib/workflow_import.py`):
- `{{TELEGRAM_BOT_TOKEN}}` — Telegram API URLs + `BOT_TOKEN` constants in Code nodes
- `{{DISCORD_BOT_TOKEN}}` — `"Bot <token>"` Authorization header values

Adding a new placeholder means (a) adding the key to the whitelist, (b) reviewing workflow JSONs to confirm the placeholder appears where intended, (c) confirming it can't be expressed as a typed n8n credential instead.

## Scan results

Initial automated scan (2026-04-17): 0 findings across known-sensitive patterns.

Follow-up manual audit (2026-04-24, pre-public-push): caught 8 remaining hardcoded bot token instances across `02-01-discord-adapter.json` (4) and `02-02-telegram-adapter.json` (4) that the original sanitizer missed — these were in HTTP Authorization headers and Code node bodies, not in credential-ref fields the sanitizer was scanning. Resolved by the env-placeholder mechanism above.

Original pattern checklist:
- Bearer / JWT tokens
- OpenRouter / Google / GitHub / Anthropic API key patterns
- Chris's gmail address
- Chris's database person_id
- Real local network IPs (.155, .157, .231)
- Real n8n workflow UUIDs (all 28 from the ID mapping, including the 4 now-removed out-of-scope ones)
- `christopher perry` / `sira.fiinikkusu` / `siravaultlore` strings

## Deltas from existing public repo sanitization

The existing `Aerys-Resonant-Span/workflows/` was previously sanitized by hand. My sanitizer closely matches its scheme but has minor stylistic differences you may want to normalize before publishing:

| My placeholder | HEAD's placeholder | Notes |
|---|---|---|
| `YOUR_CENTRAL_ERROR_WORKFLOW_ID` | `YOUR_ERROR_HANDLER_WORKFLOW_ID` | HEAD's name is cleaner, doesn't expose internal slug |
| `YOUR_OPEN_ROUTER_CREDENTIAL_ID` | `YOUR_OPENROUTER_CREDENTIAL_ID` | HEAD treats OpenRouter as one word |

These are cosmetic only — both versions are safe (no secrets leaked in either). Simple `sed` pass will normalize.

## Files excluded from sync (D-11 revised, 2026-04-17 evening)

Chris revised D-11 during Task 1 execution: out-of-scope workflows are **excluded entirely** from the public repo, not shipped as reference JSONs. Removed from `installer/workflows/`:

- `05-03-email-sub-agent.json` — email tool, slated for rebuild
- `05-03-gmail-trigger.json` — depends on email tool
- `05-03-morning-brief.json` — depends on email tool
- `voice-adapter.json` — on a separate rebuild track
- `06-01-eval-suite.json` — debug harness, not production (removed in a later pass)

Also excluded from the start:
- **Kael Discord DM (`ksLDPrBEf22vfYcF`)** — Chris's personal bot, not Aerys infrastructure.

Result: **23 workflows** remain in `installer/workflows/` — exactly the set the installer will actually deploy. Clean "repo == what installer deploys" story.

## Open items for future hardening

1. **Normalize placeholder names** if desired (two cosmetic deltas above)
2. **Review `02-04-output-router.json`** — live workflow has a **hardcoded HA Bearer token in plain value field** (line 495/1308 of live export). Refactor to use a credential (httpHeaderAuth or HA integration) for production hygiene. Worth applying the same `{{KEY}}` placeholder pattern to this if the token stays inline.
