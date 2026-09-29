# Aerys

A personal AI companion that remembers you across Discord, Telegram, and
whatever else you wire into it. Built on n8n + LangChain + pgvector with a
tiered model router that keeps costs sane.

---

## What Aerys does

- **Talks to you across channels.** Discord DMs, Discord server channels, and
  Telegram all feed the same conversation thread — your AI knows the whole
  conversation, not just the one channel you happen to be in.
- **Remembers you.** Memory extraction pipeline surfaces facts worth keeping
  (preferences, relationships, ongoing projects, important dates) and injects
  them into future conversations. Vector search for semantic recall on top of
  explicit memory.
- **Routes intelligently.** A classifier picks the right model tier per
  message: fast models for greetings and small talk, capable models for real
  work. Opus-tier calls are daily-capped so you don't wake up to a $400 bill.
- **Runs tools.** Media understanding (images, PDFs, DOCX, YouTube), web
  research (Tavily), sub-agents for specialized work. Add your own.
- **Has a personality you can edit.** `config/soul.md` is a markdown file. No
  rebuild required — n8n reads it on each execution.

---

## Architecture at a glance

```
  Discord / Telegram  →  Adapter workflows  →  Core Agent  →  Output Router
                                                   │                │
                                                   ├─ Memory ────── ┘
                                                   ├─ Identity
                                                   ├─ Tools (research, media)
                                                   └─ Model router (Gemini / Sonnet / Opus)
                                                         │
                                                         ├→ Google AI direct (Gemini tier)
                                                         └→ OpenRouter (Sonnet / Opus)
```

Everything runs in two Docker containers: **n8n** (orchestration) +
**Postgres with pgvector** (memory store). Optionally point at an external
Postgres if you already have one.

---

## Requirements

- Linux host (Debian/Ubuntu/Arch tested; macOS may work but is not first-class)
- Docker 24+ and Docker Compose v2 (the `docker compose` plugin, not the old
  standalone `docker-compose`)
- 4 GB RAM minimum, 8 GB recommended
- 20 GB free disk
- OpenRouter account (paid, for LLM calls)
- Discord bot OR Telegram bot (the installer asks for at least one)

Optional:
- Google AI / Gemini API key for the fast tier
- Tavily API key for web research

---

## Quickstart

```bash
git clone https://github.com/sira-fiinikkusu/Aerys-Resonant-Span.git aerys
cd aerys
./aerys install
```

The installer walks you through:
1. **Prerequisites check** — verifies Docker, compose, disk, ports.
2. **Credential wizard** — prompts for OpenRouter, Discord/Telegram bot
   tokens, optional Google AI + Tavily keys. Generates a random Postgres
   password for the bundled DB. Writes to `.env` with chmod 600.
3. **Docker compose generation** — writes `docker-compose.yml` wired to
   your `.env`.
4. **Database initialization** — stages migrations for first Postgres start.
5. **Config setup** — copies `soul.md` personality template with your chosen
   AI name, plus model router and app settings.

Then:

```bash
./aerys start
# wait ~30s, then visit http://localhost:5678
# complete n8n owner setup (email + password, one-time)
# Settings → API → Create API Key, copy it

./aerys upgrade-workflows
# first run: hidden prompt asks for your n8n API key, validates it, and
# saves it to .env (chmod 600) so later runs are silent. --api-key KEY
# still works as a non-interactive override.

./aerys health
```

### Why the manual n8n setup step?

Two reasons, in order of importance:

1. **It gets you inside the orchestration platform.** Aerys runs on n8n.
   Treating n8n as a black box you never open means the moment you want
   to tweak a workflow, add a tool, or debug something, you're lost.
   Thirty seconds of "click the settings gear and make an API key"
   teaches you that the platform exists and that you can touch it. This
   is the gate that opens every future customization — new workflows,
   new credentials, new adapters, debugging memory extraction, whatever
   you want to build on top. The installer gets you to a running stack;
   n8n's UI is where you extend it.

2. **Scripting owner creation is fragile across n8n versions.** The
   installer could scrape the setup page, but that would break every
   time n8n ships a UI change. Doing it by hand once keeps the
   installer forward-compatible.

---

## Common commands

```
./aerys help                  # show all verbs
./aerys install               # full install (prereqs → wizard → compose → DB → config)
./aerys check                 # verify prerequisites, change nothing
./aerys credentials           # re-run the wizard, rewrite .env
./aerys compose               # regenerate docker-compose.yml from .env
./aerys config                # regenerate soul.md + models.json + config.json
./aerys init-db               # stage / run database migrations
./aerys verify-db             # verify the Aerys schema is populated
./aerys upgrade-workflows     # install community nodes + import + activate 23 workflows
                              # (prompts for n8n API key on first run; stores in .env)
./aerys health                # end-to-end verification post-install (uses stored API key)
./aerys install-discord-watchdog  # user systemd unit that fixes the Discord IPC
                              # race on every n8n restart (recommended if both
                              # DM and guild adapters are configured)
./aerys update                # regen compose + config (post-git-pull refresh)
./aerys uninstall             # tear down deployment (prompts before destroying data)

./aerys start                 # docker compose up -d
./aerys stop                  # docker compose down
./aerys restart               # docker compose restart n8n
./aerys watch                 # follow n8n logs

./aerys rename NAME           # update AI_NAME in .env + regen soul.md
./aerys set-webhook URL       # update WEBHOOK_URL + regen compose + restart
./aerys register-telegram     # POST to Telegram's setWebhook with .env values

# global options
--deploy-dir PATH             # override the persisted deploy dir
--env-path PATH               # override the persisted .env path
--n8n-url URL                 # n8n base URL (default http://localhost:5678)
--yes                         # skip interactive prompts (pairs with uninstall)
```

`./install.sh` is a symlink to `./aerys` — existing scripts or docs using
`./install.sh --foo` keep working.

---

## Customization

### Change your AI's name or personality

Edit `config/soul.md`. Changes take effect on the next n8n execution — no
rebuild required. To swap the name in a single step:

```bash
./aerys rename Iris
./aerys restart
```

### Tune model routing

Edit `config/models.json` (see POST-INSTALL.md §4 for the schema). Restart
n8n after:

```bash
./aerys restart
```

### Expose to the internet (for Discord/Telegram webhooks)

See [POST-INSTALL.md](POST-INSTALL.md) section 5 for the Cloudflare tunnel walkthrough.

---

## Troubleshooting

If something's off, check:
1. `./aerys watch` — recent n8n logs, any errors?
2. `./aerys health` — full diagnostic
3. [POST-INSTALL.md section 10 (Troubleshooting)](POST-INSTALL.md#10-troubleshooting) for common issues

---

## Updating

```bash
git pull
./aerys update
```

`./aerys update` does the full refresh: regenerates compose + config files
from the new templates, pulls the latest `n8nio/n8n:latest` and
`pgvector/pgvector:pg16` images, and recreates containers with them. Data
and credentials are preserved (they live in mounted volumes, not images).

For workflow JSON updates, re-run separately:
```bash
./aerys upgrade-workflows
```
The current import engine is first-install only — differential updates are
a future enhancement.

---

## Uninstalling

```bash
./aerys uninstall
```

This tears down containers, wipes volumes (with confirmation), and removes
generated files. It does NOT remove the installer source or this README.

---

## Credits

Aerys was built and field-tested on a Particle Tachyon SBC starting in Feb
2026, as a personal project to see how far a single person could take an
AI companion that remembers you. The installer you're looking at was
extracted from that personal deploy into something anyone can run.

If you use it, break it, or extend it, open an issue or PR.

## License

See LICENSE.
