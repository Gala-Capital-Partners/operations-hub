# Operations Hub

Internal operations platform for a multi-brand restaurant franchisor.

| Folder    | What it is                       |
| --------- | -------------------------------- |
| `client/` | Next.js 16 + React 19 frontend   |
| `server/` | Express 5 + TypeScript API       |
| `docs/`   | Requirements, dev workflow, QA   |

## Quick start

Requires Node 22+ (`node -v`).

```bash
npm install            # installs client + server (run at repo root only)
npm run dev:server     # terminal 1 → http://localhost:4000
npm run dev:client     # terminal 2 → http://localhost:3000
```

## Before opening a pull request

```bash
npm run check          # frontend lint + backend typecheck + full build (same as CI)
```

## Docs

- [docs/README.md](docs/README.md) — requirements and architecture
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — branches, pull requests, environment variables
- [docs/db-design.md](docs/db-design.md) — identity and access database design (draft)
- [docs/QA.md](docs/QA.md) — manual and API test checklist
