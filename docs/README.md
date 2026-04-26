# Documentation Index

Aerys is a contextually-aware personal AI assistant built on n8n with persistent memory, multi-platform messaging, and per-tier model routing. This index maps all available documentation.

## Core Documents

| Document | Description |
|----------|-------------|
| [README.md](../README.md) | Project overview, architecture, features, and V2 roadmap |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | How to contribute, PR process, coding standards |
| [DEVELOPMENT.md](../DEVELOPMENT.md) | Local development environment setup and workflow |

## Operations

| Document | Description |
|----------|-------------|
| [Setup Guide](setup.md) | Full deployment: prerequisites, API keys, n8n credentials, workflow import order, verification |
| [Configuration Reference](configuration.md) | Runtime configuration: soul.md personality system, models.json model routing, environment variables, Docker volume mounts |
| [Database Schema](schema.md) | Migration history, two-database architecture, complete table reference with column documentation |

## Development History

The `development/` directory contains the full build process organized by phase:

| Phase | Directory | Focus |
|-------|-----------|-------|
| 1 | `development/phase-01/` | Foundation: database, Docker Compose, extensions |
| 2 | `development/phase-02/` | Core pipeline: adapters, core agent, output router |
| 3 | `development/phase-03/` | Identity resolution, Discord DMs, slash commands |
| 4 | `development/phase-04/` | Memory: retrieval, batch extraction, Guardian, profiles |
| 5 | `development/phase-05/` | Sub-agents: research, email, media, sub-agent lifecycle |
| 5.1 | `development/phase-05.1/` | Memory extraction quality improvements |
| 6 | `development/phase-06/` | Production: per-tier agents, eval suite, error handling |

## Reference

| Resource | Description |
|----------|-------------|
| [Workflow Exports](../workflows/) | All 27 sanitized n8n workflow JSONs |
| [Database Migrations](../migrations/) | PostgreSQL migration SQL files |
| [Evaluation Suite](../evals/) | Baseline eval data |
| [Scripts](../scripts/) | Operational scripts (adapter watcher) |

## Quick Links

- **Architecture**: [README.md Architecture section](../README.md#architecture) — Mermaid diagram of the message lifecycle
- **Memory Pipeline**: [README.md Memory Pipeline](../README.md#memory-pipeline) — Short-term, long-term, and profile memory
- **Engineering Challenges**: [README.md Engineering Challenges](../README.md#engineering-challenges) — Task runner hang, IPC race condition, and other solved problems
- **V2 Roadmap**: [README.md V2 Roadmap](../README.md#v2-roadmap) — Voice integration, Heartbeat, Capability Request Loop
