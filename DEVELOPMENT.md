# Development Guide

This guide covers how to set up a local development environment for Aerys — the contextually-aware personal AI assistant built on n8n.

## Prerequisites

- **Docker Engine 20.10+** and **Docker Compose v2**
- **Git**
- **Linux host with 4GB+ RAM** (ARM64 or x86_64)
- **API accounts:** [OpenRouter](https://openrouter.ai), [Discord](https://discord.com/developers/applications), [Telegram](https://t.me/BotFather) (Gmail and Tavily optional)

## Quick Start

```bash
git clone https://github.com/jimstratus/aerys.git
cd aerys
cp .env.example .env
# Edit .env with your API keys and credentials
docker compose up -d
```

## Environment Setup

### Configuration Files

| File | Purpose |
|------|---------|
| `.env` | API keys, database credentials, platform tokens |
| `config/soul.md` | Personality definition (loaded at runtime, editable without redeploy) |
| `config/models.json` | Model routing configuration (Gemini/Sonnet/Opus tier mapping) |

### API Credentials

All integrations require credentials configured in n8n after workflow import:

1. Open n8n at `http://localhost:5678`
2. Navigate to **Settings → Credentials**
3. Create credentials for each service (OpenRouter, Discord, Telegram, Gmail, Tavily)

See [Setup Guide](docs/setup.md) for full credential configuration details.

## Architecture Overview

Aerys uses 27 interconnected n8n workflows across six subsystems:

```
Adapters → Identity Resolution → Memory Retrieval → Core Agent → Per-Tier Agents → Output Router
```

### Workflow Phases

| Phase | Purpose | Workflows |
|-------|---------|-----------|
| 1 | Foundation | Database, extensions, core tables |
| 2 | Core Pipeline | Discord/Telegram adapters, Core Agent, Output Router |
| 3 | Identity | Identity Resolver, Discord DMs, slash commands |
| 4 | Memory | Memory retrieval, batch extraction, Guardian, profiles |
| 5 | Sub-Agents | Research (Tavily), Email (Gmail), Media analysis |
| 6 | Production | Per-tier agents, eval suite, error handling, extractors |

### Key Architectural Decisions

- **Sub-workflow pattern** — Each model tier (Gemini/Sonnet/Opus) runs as a separate sub-workflow to avoid n8n task runner hangs when workflows exceed 6 LangChain tool nodes
- **Context recovery** — Downstream nodes reference upstream nodes directly via `$('NodeBeforeAgent').item.json` because n8n's AI Agent node strips all input fields
- **Personality separation** — `soul.md` loads at runtime via the Core Agent's Load Config node; personality changes take effect on the next incoming message

## Development Workflow

### Importing Workflows

1. Open n8n at `http://localhost:5678`
2. Navigate to **Workflows → Import from File**
3. Import workflows from `workflows/` in dependency order (see [Setup Guide](docs/setup.md))
4. Configure credentials for each workflow
5. Activate workflows in order

### Testing Changes

- Import the modified workflow JSON into a test n8n instance
- Configure test credentials (never use production API keys)
- Activate and send test messages through each platform adapter
- Verify message flow through the full pipeline
- Check debug traces in the admin-only Discord channel

### Database Migrations

Migrations live in `migrations/` and execute automatically via `docker-entrypoint-initdb.d` in alphabetical order. The Aerys application database is separate from n8n's internal database.

To add a new migration:

1. Create a new SQL file in `migrations/` with the next available phase number
2. Test against a fresh PostgreSQL instance
3. Document schema changes in `docs/schema.md`

### Workflow Development Conventions

- **Descriptive node names** — Every node should clearly describe its purpose
- **Sticky notes** — Document complex node configurations with n8n sticky notes
- **Credential sanitization** — Always redact API keys from exported workflow JSONs before committing
- **IPC ordering** — Discord adapters must activate DM-first, guild-second; see `scripts/discord-adapter-watcher.sh`

## Code Organization

```
aerys/
├── workflows/          # 27 sanitized n8n workflow JSONs
├── migrations/         # PostgreSQL migration files
├── config/             # soul.md, models.json (runtime config)
├── docs/               # Documentation
├── scripts/            # Operational scripts (adapter watcher, etc.)
├── evals/              # Evaluation suite data
├── development/        # Development history by phase
├── .env.example        # Environment variable template
├── docker-compose.yml  # Docker Compose stack definition
└── LICENSE             # MIT License
```

## Debugging

### Debug Traces

Every response generates a debug trace pushed to an admin-only Discord channel, showing:
- Intent classification result
- Model tier selection
- Memory retrieval results
- Tool calls made

### Central Error Handler

Workflow `06-03-central-error.json` catches failures across all 27 workflows, logs structured error data, and sends notifications to the error channel.

### Common Issues

- **Workflow won't activate** — Check that all sub-workflow references point to valid workflow IDs
- **Memory retrieval returns empty** — Verify pgvector extension is enabled and embeddings were generated
- **Discord adapter silent** — Run `scripts/discord-adapter-watcher.sh` to fix IPC ordering
- **Code nodes timing out** — Ensure each workflow has fewer than ~20 nodes; split into sub-workflows if needed

## Running Tests

The eval suite in `evals/` provides baseline comparison data:

```bash
# Import the eval workflow
# 06-01-eval-suite.json
# Run against test conversations
```

## License

MIT License — see [LICENSE](LICENSE) for details.
