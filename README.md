# Lumen Health

A care-tasks web app **and** the platform that deploys, monitors, and recovers it.

- **App** — Next.js web + Hono/tRPC API + Neon Postgres (Drizzle), pnpm/Turbo monorepo
- **Infra** — Terraform builds staging + prod Azure VMs (VNet/NSG/IP per env)
- **CI/CD** — GitHub Actions: test → build images → GHCR → auto-deploy staging → approval-gated prod
- **Observability** — Prometheus scrapes `/metrics`, Grafana dashboard, 3 alert rules, fault-injection endpoint for game days

## Live environments

| | Staging | Production |
|---|---|---|
| Web | `http://lumen-staging.eastus.cloudapp.azure.com:3001` | `http://lumen-prod.eastus.cloudapp.azure.com:3001` |
| API | `…:3000` (`/health` `/ready` `/metrics` `/version`) | same |
| Prometheus | `…:9090` | same |
| Grafana | `…:3002` (admin/admin) | same |

## Evidence pack

| Requirement | Where |
|---|---|
| Architecture diagram | [`docs/architecture.md`](docs/architecture.md) |
| Runbook | [`docs/runbook.md`](docs/runbook.md) |
| Game-day write-up | [`docs/game-day.md`](docs/game-day.md) |
| Alert rules | [`monitoring/alerts.yml`](monitoring/alerts.yml) |
| Dashboard screenshot (error spike + firing alert) | [`docs/evidence/screenshot-dashboard-error-spike.png`](docs/evidence/screenshot-dashboard-error-spike.png) |
| Prometheus alert firing screenshot | [`docs/evidence/screenshot-alert-HighErrorRate.png`](docs/evidence/screenshot-alert-HighErrorRate.png) |
| Pipeline definition | [`.github/workflows/ci.yml`](.github/workflows/ci.yml) |
| Terraform (both envs) | [`infra/terraform/`](infra/terraform) |
| Nine-step notes | `docs/notes/` |

## Run it locally

```bash
pnpm install                 # installs + runs varlock codegen
# add apps/server/.env (DATABASE_URL, CORS_ORIGIN) and apps/web/.env
pnpm run db:push             # apply schema
pnpm run dev                 # web :3001, api :3000
```

Or with containers (needs Docker running):

```bash
pnpm run docker:up           # web :3001, api :3000, prometheus :9090, grafana :3002
```

## Deploy / operate

- **Release:** push to `main` → CI tests, builds sha-tagged images, deploys
  staging, health-gates, waits for approval → prod (same image).
- **Rollback:** Actions → ci → Run workflow → `tag` = previous commit sha.
- **Infra:** `infra/README.md` (workspaces per env; apply = rebuild from code).
- **Incidents & drills:** `docs/runbook.md`.

## Project structure

```
apps/web        Next.js frontend (:3001)
apps/server     Hono + tRPC API (:3000), ops endpoints + metrics
packages/{ui,api,db,config}   shared workspace packages
infra/terraform Azure staging/prod (workspaces, tfvars per env)
monitoring/     Prometheus config + alert rules, Grafana provisioning
.github/workflows/ci.yml      the whole pipeline
docs/           architecture, runbook, game day, evidence, notes
```

## App notes (scaffold docs)

- UI primitives live in `packages/ui` (shadcn/ui); tokens in
  `packages/ui/src/styles/globals.css`
- Env config is varlock-driven: schemas per app in `.env.schema`; secrets
  never committed — see `docs/runbook.md` §7
- `pnpm run check` = Biome lint/format; `pnpm run check-types` = typecheck
