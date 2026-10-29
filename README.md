# Mystique

Ticketing platform for the BMMV 21 batch party: ticket sales go live on **2 Nov 2026**, and the event is on **26 Dec 2026**.

- Spec: [docs/ticketing-architecture.md](docs/ticketing-architecture.md)
- Work plan, task IDs and owners: [docs/work-plan.md](docs/work-plan.md)

## Layout

```
web/                  Vite + React PWA (streams B and C)       → web/README.md
supabase/
  migrations/         SQL schema, functions and RLS (stream A) → supabase/README.md
  functions/          Edge Functions (Deno)
  tests/              pgTAP + concurrency tests
  seed.sql            local/staging seed data only
load-tests/           k6 scripts (Q-02)
docs/                 spec, work plan, decisions, runbook
.github/workflows/    CI, deploys, nightly backup (D-03, D-14)
```

## Environments

| Env | Supabase project | Site |
|---|---|---|
| local | `pnpm db:start` (Docker) | http://localhost:5173 |
| staging | `mystique-staging` (Singapore) | https://mystique-staging.pages.dev |
| prod | `mystique-prod` (Singapore) | https://mystique-26.pages.dev |

Never edit the prod schema in the dashboard. All changes go through `supabase/migrations/` and CI.

## Getting started

Requirements: Node 24, Docker, and pnpm (`corepack enable --install-directory ~/.local/bin pnpm`).

```bash
pnpm install
pnpm db:start      # local Supabase stack; the first run downloads several GB
pnpm db:reset      # re-apply migrations + seed.sql
pnpm db:test       # pgTAP tests
```

Credentials live in `.env.staging` / `.env.prod`. Copy `.env.example`; the real files are gitignored. Never paste secrets into chat, issues or commits.

## Branches and deploys

1. Branch from `staging` (`feat/A-05-user-functions`), then open a PR **into `staging`**.
2. CI runs (secrets & dependencies, database + pgTAP, web). The PR merges only when it's green and up to date.
3. The merge deploys to **staging** automatically.
4. Release: PR `staging` → `prod`. No CI (the same code already passed); only the release lead approves.
5. The merge to `prod` deploys to **production** after the release lead approves the deploy.

`main` is not used.

## Rules

- Every task references its ID from the work plan (e.g. `A-05`, `SD-11`) in its commit message and PR.
- Every new SQL function needs an explicit `grant execute` block (spec §5.4, SD-3).
- Dependencies must be at least 14 days old (`minimumReleaseAge` in `pnpm-workspace.yaml`).
