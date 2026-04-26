# Contributing to Aerys

Thank you for your interest in contributing to Aerys! This document covers how to contribute to the contextually-aware personal AI assistant built on n8n.

## Code of Conduct

Be respectful. Treat others as you'd want to be treated. No exceptions.

## How to Contribute

### Reporting Bugs

Open an issue on GitHub with:

- A clear, descriptive title
- Steps to reproduce the bug, including which workflow(s) are affected
- Expected vs. actual behavior
- Environment details (n8n version, PostgreSQL version, Docker setup)
- Any relevant debug traces or error logs

### Suggesting Enhancements

Open an issue with:

- A clear description of the feature or enhancement
- The problem it solves
- How it integrates with the existing 27-workflow architecture
- Any impact on the memory pipeline, identity system, or model routing

### Pull Request Process

1. **Fork the repository** and create a feature branch from `main`.
2. **Discuss first** for large changes — open an issue before modifying workflows.
3. **Document your changes** — update relevant docs in `docs/` and the workflow JSONs themselves.
4. **Test your changes** — verify workflows activate and execute correctly in a test n8n instance.
5. **Ensure no credentials are exposed** — workflow JSONs must be sanitized before commit.
6. **Submit the PR** with a clear description linking to the issue.

### Security Disclosures

DO NOT open public issues for security vulnerabilities, especially anything related to credential exposure in workflow JSONs, memory privacy leaks, or IPC vulnerabilities. Contact the maintainers directly.

## Development Environment

See [DEVELOPMENT.md](DEVELOPMENT.md) for complete setup instructions.

### Quick Setup

```bash
# Clone
git clone https://github.com/jimstratus/aerys.git
cd aerys

# Configure environment
cp .env.example .env
# Edit .env with your API keys and credentials

# Start the stack
docker compose up -d
```

## Workflow Development

### Architecture

Aerys uses 27 interconnected n8n workflows spanning 7 development phases. The message lifecycle flows through six subsystems:

1. **Adapters** — normalize platform-specific input (Discord, Telegram, Gmail)
2. **Identity Resolution** — map platform identities to unified `person_id`
3. **Memory Retrieval** — hybrid search across short-term, long-term, and profile memory
4. **Core Agent** — intent classification and model tier routing
5. **Per-Tier Agents** — Gemini Flash Lite (greetings), Sonnet (conversation), Opus (research)
6. **Output Router** — format and deliver responses to the originating platform

### Key Conventions

- **Sub-workflow architecture** — each model tier runs as a separate workflow to avoid n8n task runner hangs
- **Context recovery** — downstream nodes reference upstream nodes directly via `$('NodeBeforeAgent').item.json`
- **Personality separation** — `soul.md` loaded at runtime, editable without workflow redeployment
- **Credential sanitization** — always redact API keys and tokens from exported workflow JSONs
- **IPC ordering** — Discord adapters must activate in specific order (DM first, guild second)

### Testing Workflows

- Import workflow JSONs into a test n8n instance
- Configure test credentials (never use production API keys)
- Activate workflows in dependency order (see `docs/setup.md`)
- Verify message flow through the full pipeline
- Check debug traces in the admin-only channel

## Coding Standards

### Workflow JSONs

- Keep workflow JSONs clean and well-organized
- Include descriptive node names
- Document complex node configurations with sticky notes
- Sanitize all credentials before commit

### Database Migrations

- SQL migrations live in `migrations/`
- Follow the numbered naming convention
- Test migrations against a fresh PostgreSQL instance
- Document schema changes in `docs/schema.md`

### Documentation

- Update `docs/` when adding or modifying workflows
- Document new environment variables in `.env.example`
- Update the Architecture diagram in README.md for structural changes

## Documentation

- [README.md](README.md) — project overview and architecture
- [Setup Guide](docs/setup.md) — prerequisites and deployment
- [Configuration Reference](docs/configuration.md) — soul.md, model routing, environment variables
- [Database Schema](docs/schema.md) — migration reference and table documentation
- [Documentation Index](docs/README.md) — full docs map

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
