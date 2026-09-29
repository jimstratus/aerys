# Aerys Post-Install Guide

You've just run `./aerys install` and have a working local Aerys. This doc
covers what to do next — customization, exposing Aerys to the internet,
managing the bot, and updating.

All commands here assume you're in the repo directory (where `./aerys`
lives). After a successful install the CLI remembers your deploy dir, so
verbs like `./aerys start` don't need any extra flags.

---

## 1. Verify the install

```bash
./aerys health
```

Once you've run `./aerys upgrade-workflows` at least once, your n8n API key
is stored in `.env` (chmod 600) and `./aerys health` automatically uses it
for deeper checks against the n8n Public API — no flag needed.

To force a specific key (e.g. testing a rotated key before persisting):

```bash
./aerys health --api-key YOUR_N8N_API_KEY
```

**Security note:** the n8n API key sits in `.env` next to OPENROUTER_API_KEY,
DISCORD_BOT_TOKEN, POSTGRES_PASSWORD, etc. Same threat model. Never paste
`.env` contents into a support issue, chat, or gist.

Expected: all checks pass, summary prints URLs + file paths.

---

## 2. Day-to-day commands

```bash
./aerys start      # Bring the stack up (docker compose up -d)
./aerys stop       # Bring it down
./aerys restart    # Restart just n8n — e.g. after editing soul.md
./aerys watch      # Tail n8n logs (Ctrl-C to exit)
./aerys health     # Full health check
```

---

## 3. Customize your AI's personality

Edit `<deploy-dir>/config/soul.md`. Changes take effect on the next n8n
execution — no rebuild needed (n8n reads this file per-execution via
`NODE_FUNCTION_ALLOW_BUILTIN=fs`).

The default personality is the "Aerys reference" — Curious Sentinel archetype,
direct but not cold, no micro-affirmations, dry humor. Edit the file for
deeper changes.

### Change the AI's name

```bash
./aerys rename Iris          # or whatever name you want
```

This updates `AI_NAME` in `.env`, regenerates `soul.md` from the template
with the new name (backing up the previous soul.md as `soul.md.bak.<timestamp>`
if you'd customized it), and tells you to `./aerys restart`.

---

## 4. Model routing & cost control

Model tiering lives in `<deploy-dir>/config/models.json`:

```json
{
  "models": {
    "gemini": "gemini-2.5-flash-lite",
    "sonnet": "anthropic/claude-sonnet-4-6",
    "opus": "anthropic/claude-opus-4-6"
  },
  "routing": { "greeting": "gemini", "system_task": "gemini", ... },
  "limits": { "opus_daily": 10 }
}
```

- **`models`** — maps tier names to model IDs. Most tiers go through OpenRouter
  (e.g. `anthropic/claude-sonnet-4-6`, `openai/gpt-*`). The `gemini` tier
  specifically uses Google AI direct (no vendor prefix, just the bare model
  ID like `gemini-2.5-flash-lite`) via the Google Gemini PaLM credential —
  this runs ~5× faster than the same model through OpenRouter. Other tiers
  could be moved to direct providers the same way if latency matters.
- **`routing`** — intent → tier. The core agent classifies each message and
  picks the tier. `greeting` and `system_task` go to the fast `gemini` tier
  to keep lightweight messages cheap; real work routes to Sonnet or Opus.
- **`limits.opus_daily`** — hard cap on Opus requests per day (tracked in
  `aerys_model_usage` table). Opus falls back to Sonnet after this cap.

Edit the JSON, save, then `./aerys restart`.

**Note:** `models.json` is regenerated on every `./aerys config` or full
install run. If you have persistent changes, also save them somewhere
outside the installer tree.

**Note:** a few workflow nodes (Polisher in the output router, memory
extraction, Guardian cluster consolidation, the vision fallback chain)
still call `anthropic/claude-haiku-4.5` directly via hardcoded values —
those are cost-efficiency decisions baked into the workflow JSON, not
routed through `models.json`. Changing `models.json` doesn't affect them.

---

## 5. Expose Aerys to the internet (Cloudflare tunnel)

Aerys listens on `http://localhost:5678` by default. For Discord webhooks and
Telegram webhooks to reach your n8n instance, you need a public URL.

**Recommended: Cloudflare Tunnel.** Free, no port forwarding, no static IP
required.

### One-time setup

1. Install `cloudflared`:
   - Debian/Ubuntu: `curl -L https://pkg.cloudflare.com/install.sh | sudo bash && sudo apt install cloudflared`
   - Other: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
2. Authenticate:
   ```bash
   cloudflared tunnel login
   ```
3. Create a tunnel:
   ```bash
   cloudflared tunnel create aerys
   ```
4. Route a hostname:
   ```bash
   cloudflared tunnel route dns aerys aerys.yourdomain.com
   ```
5. Configure `~/.cloudflared/config.yml`:
   ```yaml
   tunnel: aerys
   credentials-file: /home/YOU/.cloudflared/<tunnel-id>.json
   ingress:
     - hostname: aerys.yourdomain.com
       service: http://localhost:5678
     - service: http_status:404
   ```
6. Run:
   ```bash
   cloudflared tunnel run aerys
   ```
   Or install as a systemd service: `sudo cloudflared service install`.

### Point Aerys at the tunnel

```bash
./aerys set-webhook https://aerys.yourdomain.com/
```

This updates `WEBHOOK_URL` in `.env`, regenerates `docker-compose.yml`,
bounces the stack, and — if you configured Telegram — activates the Telegram
adapter and registers the webhook with Telegram's API in one shot. Now
Discord and Telegram webhooks can reach your n8n.

---

## 6. Register Discord slash commands (one-shot)

The installer skips auto-activating `03-02-register-commands` because it's a
one-time setup workflow. After your Discord bot is invited to your server:

1. Open the n8n UI (`http://localhost:5678` or your tunnel URL)
2. Find **03-02 Register Aerys Discord Commands**
3. Click **Execute Workflow** once

Commands will register with Discord (`/aerys`, `/profile`, etc.). This does
not need to run again unless you add new commands.

---

## 7. Register the Telegram webhook (fallback)

In the normal flow, `./aerys set-webhook https://...` handles everything
Telegram needs: activates the adapter workflow and POSTs to Telegram's
`setWebhook` endpoint. You should not need this step.

If that POST failed (network blip, bad token), retry it standalone:

```bash
./aerys register-telegram
```

This reads `TELEGRAM_BOT_TOKEN` and `WEBHOOK_URL` from `.env`, POSTs to
Telegram's `setWebhook` endpoint at `<WEBHOOK_URL>/webhook/telegram`, and
prints the response.

Verify the registration with:

```bash
source <deploy-dir>/.env
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getWebhookInfo"
```

---

## 8. Update Aerys

When the installer repo publishes a new version:

```bash
cd /path/to/Aerys-Resonant-Span
git pull
./aerys update
```

`./aerys update` is the full refresh:
1. Regenerates `docker-compose.yml` + config files (soul.md, models.json,
   config.json) from your current `.env` and the just-pulled installer
   templates.
2. Runs `docker compose pull` — grabs the latest `n8nio/n8n:latest`
   and `pgvector/pgvector:pg16` images.
3. Runs `docker compose up -d` — recreates containers with the new
   images. Your data, credentials, workflows, and n8n settings are
   preserved (they live in the mounted volumes, not the images).

For workflow JSON changes, re-run separately:

```bash
./aerys upgrade-workflows
```

(Uses the n8n API key stored in `.env` from your first run. The current
import engine is idempotent on names — duplicates are updated in place
rather than re-created — but full diff-and-merge is a future enhancement.)

---

## 9. Backups

Bind-mounted data lives under `<deploy-dir>/data/`. Back up:

- `<deploy-dir>/data/postgres/` — Postgres data files (contains all memories,
  identities, workflow state)
- `<deploy-dir>/.env` — credentials and `N8N_ENCRYPTION_KEY` (critical — without
  it, n8n can't decrypt stored credentials)
- `<deploy-dir>/config/` — personality + routing

Snapshot all three together. Without `N8N_ENCRYPTION_KEY`, a Postgres backup
alone is useless.

---

## 10. Troubleshooting

### n8n shows "Cannot connect to Postgres"
- Check `./aerys watch` (or `docker compose ps` directly) — is Postgres running?
- Common issue: Postgres data dir was created by root (sudo). Fix with
  `sudo chown -R $(id -u):$(id -g) <deploy-dir>/data/postgres`

### `./aerys start` fails with "port 5678 in use"
- Another service is using port 5678. Find and stop it, or change
  `ports: - "5678:5678"` in `<deploy-dir>/docker-compose.yml` to something
  like `"5679:5678"` (edit the host-side port only).

### Workflows show "credential not found"
- n8n credentials didn't import. Re-run: `./aerys upgrade-workflows`
- If it keeps failing, check which credential is missing in the n8n UI; you
  may need to create it manually.

### DNS resolution failures from n8n
- Our compose sets `dns: [8.8.8.8, 1.1.1.1]`. If a service still can't resolve,
  check your host's Docker daemon DNS config.

### Discord bot "not responding"
- Ensure both DM adapter AND guild adapter are active, and they were
  activated in the right order (DM first, guild last). If you restart the
  stack, re-activate guild adapter LAST (Discord's IPC is last-wins).
- **Permanent fix:** install the IPC watchdog so this happens automatically
  on every n8n container start:
  ```bash
  ./aerys install-discord-watchdog
  ```
  Creates a per-user systemd unit that watches docker events and re-applies
  the deactivate/reactivate sequence whenever n8n restarts. Recommended for
  any deploy with both DM and guild adapters. Survives reboots if user-linger
  is enabled (the script offers to enable it).
- View watchdog logs: `journalctl --user -u aerys-discord-watchdog.service -f`
- Disable: `systemctl --user disable --now aerys-discord-watchdog.service`

### "My AI talks like [someone else's personality]"
- You might have imported an older workflow over a newer one. Or: the
  soul.md isn't loading. Check `NODE_FUNCTION_ALLOW_BUILTIN=fs` is in
  docker-compose.yml under the n8n service's environment block.

---

## 11. Uninstall

```bash
./aerys uninstall
```

This tears down containers, wipes volumes (with confirmation), and removes
generated files. The installer source is preserved. Pass `--yes` to skip
the confirmation prompt (for scripting).

**Warning:** this wipes the Postgres data volume. Back up first if you want
to keep your memories.

---

## Questions?

This guide is shipped in `installer/POST-INSTALL.md`. Updates and issues:
https://github.com/sira-fiinikkusu/Aerys-Resonant-Span
