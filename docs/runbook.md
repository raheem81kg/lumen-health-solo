# Lumen Health — Runbook

Everything needed to deploy, monitor, debug, and recover the platform.
Written so the game-day responder can operate using only this document.

## 0. Reference

| Thing | Staging | Production |
|---|---|---|
| Web app | `http://lumen-staging2.eastus.cloudapp.azure.com:3001` | `http://lumen-prod2.eastus.cloudapp.azure.com:3001` |
| API | `http://lumen-staging2.eastus.cloudapp.azure.com:3000` | `http://lumen-prod2.eastus.cloudapp.azure.com:3000` |
| Prometheus | `http://lumen-staging2.eastus.cloudapp.azure.com:9090` | `http://lumen-prod2.eastus.cloudapp.azure.com:9090` |
| Grafana | `http://lumen-staging2.eastus.cloudapp.azure.com:3002` | `http://lumen-prod2.eastus.cloudapp.azure.com:3002` |
| Dashboard | `…:3002/d/lumen-api-overview` | same path on prod host |

- SSH: `ssh -i ~/.ssh/lumen-deploy lumenadmin@<host>`
- Deploy dir on VMs: `~/deploy/lumen-health` (compose file, `apps/*/.env`, `monitoring/`)
- Grafana login: `admin` / `admin`
- Repo secrets (Settings → Secrets → Actions): `DEPLOY_SSH_KEY`, `DATABASE_URL`, `GHCR_PAT`

## 1. Deploy (normal release)

1. Merge / push to `main`. The `ci` workflow runs automatically:
   `test → build web+server images (tag = commit sha) → deploy-staging → health gate`.
2. Watch the run in **Actions**. `deploy-staging` must be green — its health
   gate curls `localhost:3000/health` and `localhost:3001/` on the VM; a bad
   release fails here and cannot reach prod.
3. `deploy-prod` then waits for approval: open the run → **Review deployments**
   → **Approve**. The same sha-tagged images roll out to prod.

## 2. Rollback a bad release

Rollback = redeploy a previous image tag. Images are tagged by commit sha, so:

1. Find the last-known-good commit sha (`git log --oneline`, or the previous
   green run in Actions).
2. **Actions → ci → Run workflow** → set `tag` to that sha → Run.
3. The pipeline redeploys that tag to staging, health-gates it, then awaits
   your approval for prod. Target: under 10 minutes end-to-end.

Emergency alternative (straight on the VM, if Actions/GitHub is down):

```bash
ssh -i ~/.ssh/lumen-deploy lumenadmin@<env-host>
cd ~/deploy/lumen-health
export GITHUB_REPOSITORY=raheem81kg/lumen-health-solo IMAGE_TAG=<good-sha>
docker compose pull && docker compose up -d
```

## 3. Alert response

Alerts live in `monitoring/alerts.yml`. Check current state:
`http://<env-host>:9090/alerts` or the "Firing Alerts" panel on the dashboard.

### ApiDown — `up{job="lumen-api"} == 0` (critical)

API container is down or unreachable.

```bash
curl -m 8 http://<env-host>:3000/health                    # is it really down?
ssh -i ~/.ssh/lumen-deploy lumenadmin@<env-host>
cd ~/deploy/lumen-health
docker compose ps                                          # which container died?
docker compose logs --tail 50 server                       # why?
docker compose up -d server                                # restart it
curl http://localhost:3000/health                          # confirm recovery
```

If the container keeps crash-looping, the last deploy is suspect → rollback (§2).

### HighErrorRate — `rate(http_errors_total[5m]) > 0.1` (warning)

5xx responses are flowing. Check whether it's a real release regression or
injected fault:

```bash
# check if a game-day fault is armed
curl -X POST http://<env-host>:3000/__debug/fault \
  -H 'content-type: application/json' -d '{}'         # returns current faultRate
docker compose logs --tail 50 server                     # real 5xx vs injected
```

- Injected fault (game day): `curl -X DELETE http://<env-host>:3000/__debug/fault`
- Real regression: rollback (§2).

### HighLatencyP95 — p95 > 1s for 1m (warning)

Usually DB (Neon) slowness or a hot endpoint. Check the latency panel, confirm
`/ready` (does a `select 1` against the DB):

```bash
curl http://<env-host>:3000/ready
```

If DB unreachable → check Neon status; the app recovers on its own when the DB does.

## 4. Fault injection (game day / drills)

```bash
# break it: every tRPC call 500s
curl -X POST http://<env-host>:3000/__debug/fault \
  -H 'content-type: application/json' -d '{"rate":1}'

# generate traffic so the error rate climbs
for i in $(seq 1 60); do curl -s -o /dev/null http://<env-host>:3000/trpc/x; sleep 1; done

# watch HighErrorRate go pending → firing (≈60-90s)
open http://<env-host>:9090/alerts

# fix it
curl -X DELETE http://<env-host>:3000/__debug/fault
```

Also killable directly: `docker compose stop server` → `ApiDown` fires within ~30s.

## 5. Routine ops

```bash
ssh -i ~/.ssh/lumen-deploy lumenadmin@<env-host>
cd ~/deploy/lumen-health
docker compose ps                    # container status
docker compose logs -f server        # follow API logs
docker compose restart web           # restart one service
docker compose pull && docker compose up -d   # pick up :latest manually
```

## 6. Rebuild an environment from zero

```bash
cd infra/terraform
export TF_VAR_subscription_id=<sub-id>
export TF_VAR_ssh_public_key="$(cat ~/.ssh/lumen-deploy.pub)"
terraform init
terraform workspace select staging   # or prod
terraform apply -var-file=envs/staging.tfvars
# then push any commit → pipeline deploys the app onto the fresh VM
```

Cautions: never `apply` while a destroy is still propagating (Azure eventual
consistency → "present but absent" errors; fix = wait for the RG delete to
finish, then `terraform import` any orphan). State lives in workspaces —
`prod.tfvars` in the `staging` workspace is refused by the check block.

## 7. Secrets

- Nothing secret is committed: `.env*`, `terraform.tfstate*`, keys are gitignored.
- App secrets live in GitHub Actions secrets → written onto the VM as
  `apps/*/.env` at deploy time, never baked into images.
- Build images get **placeholder** env (`localhost` URLs) via BuildKit secrets —
  required only because varlock validates at build time.
- Rotate `DEPLOY_SSH_KEY`: `ssh-keygen -t ed25519 -f ~/.ssh/lumen-deploy`,
  update the GitHub secret, and install the new pub key on both VMs:

```bash
az vm run-command invoke -g rg-lumen-<env> -n vm-lumen-<env> \
  --command-id RunShellScript --scripts \
  "echo '<new-pub>' > /home/lumenadmin/.ssh/authorized_keys && \
   chown lumenadmin:lumenadmin /home/lumenadmin/.ssh/authorized_keys"
```
