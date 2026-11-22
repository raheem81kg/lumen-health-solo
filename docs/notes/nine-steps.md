# Nine Steps — Lumen Health (solo project)

- **Name:** Raheem Gordon
- **Project:** Lumen Health — a care-tasks app (Next.js web + Hono/tRPC API + Neon Postgres) plus the platform that deploys, monitors and recovers it
- **Repository:** https://github.com/raheem81kg/lumen-health-solo (private while developing)
- **Roles covered:** all four (solo submission) — so the notes cover all four tools: Terraform, GitHub Actions, Prometheus + Grafana, and the secrets/rollback tooling
- **Files:** `infra/terraform/`, `.github/workflows/ci.yml`, `monitoring/`, `docs/runbook.md`, `docs/game-day.md`

Every step is answered in my own words using examples from this project.

---

# Part 1 — Terraform (infrastructure owner)

## Step 1 — Purpose

Terraform exists so the two environments are code, not clicks. Instead of me remembering which portal checkboxes built staging, `terraform apply` rebuilds the whole thing — VM, network, firewall, public IP, DNS label — from the same files every time. That is what makes "rebuild staging and production from code with no manual steps" testable instead of a promise.

I picked Terraform over hand-rolled `az` scripts because it tracks state: it knows what it built, diffs reality against the code, and only changes the difference.

## Step 2 — Use

In real work Terraform is how teams stop environments drifting: prod and staging come from one `main.tf` with different `tfvars`, so identical-by-construction.

Real example from this project: `terraform apply -var-file=envs/staging.tfvars` and `terraform apply -var-file=envs/prod.tfvars` created two isolated environments — `rg-lumen-staging` on `10.10.0.0/16`, `rg-lumen-prod` on `10.20.0.0/16` — each with its own VNet, subnet, NSG, public IP, NIC and VM, and its own DNS name (`lumen-staging2.eastus.cloudapp.azure.com`, `lumen-prod…`). The only things that differ between them are variables.

## Step 3 — Versions

| Axis | Options | What I used |
|---|---|---|
| State location | local `terraform.tfstate` / remote backend (Azure Storage, S3) | local, gitignored — documented remote option in `versions.tf` |
| Env separation | workspaces / separate state files / separate dirs | Terraform **workspaces** (`staging`, `prod`) |
| Provisioners | `remote-exec`, `custom_data` (cloud-init), config mgmt (Ansible) | `custom_data` → `cloud-init.yaml` installs Docker |
| Provider model | HCL (Terraform/Pulumi) vs ARM templates/Bicep (Azure-native) | HCL + `hashicorp/azurerm` |

Workspaces deserve a note: `terraform workspace select prod` switches the *state file* under `terraform.tfstate.d/`, so each env has its own memory of what exists. The trap — applying `prod.tfvars` in the `staging` workspace — is blocked by a `check` block in `main.tf` that refuses a workspace/tfvars mismatch, because without it apply would have renamed staging into prod.

## Step 4 — Alternatives

| Alternative | Pick it when | Why not for us |
|---|---|---|
| Azure portal (clicking) | One-off toy, never rebuilt | The assignment's whole point is rebuild-from-code |
| Bicep / ARM templates | Azure-only shop, want native toolchain | Terraform is more common and I already knew it |
| Pulumi | Want a real programming language over HCL | More moving parts; HCL is enough for 8 resources |
| Ansible + existing VMs | Machines already exist, need config only | We had no machines — needed provisioning, not just config |
| DigitalOcean `droplet` resource | Fastest possible demo | Azure was the class target and a droplet hides the networking the rubric grades |

## Step 5 — Limits

Named failure modes that actually bit me:

- **Quota is checked at apply time, not plan time.** The trial subscription caps at 4 cores *per region*, and my two old deallocated VMs still held their cores. First apply failed at the VM step with `QuotaExceeded`. Deleting the old VMs (and their orphaned public IPs — public IPs are a separate 3-per-region quota) fixed it.
- **Azure's eventual consistency breaks state.** Applying while a resource-group delete was still propagating produced "Root object was present, but now absent" — resources created but never recorded in state. The fix was `terraform import <addr> <azure-id>` per orphan; the lesson was to wait for the delete to finish before re-applying.
- **Local state is a single point of failure.** Lose `terraform.tfstate.d/` and Terraform forgets what it owns — that's why real teams use a remote backend (noted in `versions.tf`, not implemented for a demo).
- **Empty variables fail late.** `TF_VAR_ssh_public_key` unset once built a VM with no SSH key at all. I added a `validation` block so plan fails immediately instead of shipping a locked box.
- **Provider bugs are real.** The read-after-write race in the Network RP is a documented azurerm issue — HCL can't defend you from the provider underneath it.

## Step 6 — Logs and observability

Terraform's own observability is plan/apply output: `plan` shows the diff before anything happens (+ create, ~ change, - destroy), and apply narrates each resource as it goes. When an apply fails, the error names the resource and the Azure error verbatim — the `QuotaExceeded` and `SkuNotAvailable` errors both surfaced this way.

Deeper: `TF_LOG=debug terraform apply` exposes the raw ARM calls; `az vm run-command invoke` let me look inside the VM (checking `authorized_keys`, `/var/log`) without SSH when SSH itself was the broken thing; `terraform show`/`-json` dumps recorded state for inspection. `terraform import` + `plan` showing "No changes" was how I confirmed the orphans were fully adopted.

## Step 7 — Configuration

What actually varies per environment, in `envs/*.tfvars`: `environment`, `location`, `vnet_address_space`, `subnet_address_prefixes`. Everything else is shared in `main.tf`.

Settings that matter:

- `TF_VAR_subscription_id`, `TF_VAR_ssh_public_key` — injected via env vars, never written to a file that could be committed.
- `admin_ssh_key { public_key = var.ssh_public_key }` — the deploy key `lumenadmin` + `~/.ssh/lumen-deploy.pub`.
- `custom_data` → `cloud-init.yaml` — the VM's first boot installs Docker + Compose and creates `/opt/lumen`.
- `azurerm_network_security_rule` — opens 22 (SSH) and the app ports `[3000, 3001, 3002, 9090]` only.
- `public_ip { domain_name_label }` — gives the FQDN the workflow hardcodes.
- The `check` block — fails `plan` if workspace ≠ tfvars environment.

## Step 8 — Procedures

```bash
cd infra/terraform
export TF_VAR_subscription_id="…"          # secret-ish, via env var
export TF_VAR_ssh_public_key="$(cat ~/.ssh/lumen-deploy.pub)"
terraform init                            # once
terraform workspace select staging        # or prod
terraform plan  -var-file=envs/staging.tfvars   # always diff first
terraform apply -var-file=envs/staging.tfvars
terraform destroy -var-file=envs/staging.tfvars # full teardown
```

Troubleshooting: "present but now absent" → find the orphan in the portal → `terraform import azurerm_subnet.x <azure-id>` → re-`plan` should show no diff. Quota errors → check `az vm list-usage`, delete parked VMs/IPs. Apply hangs after a destroy → wait for `az group exists -n rg-…` to return false.

## Step 9 — Internals

Terraform is a graph engine over a state file. On `plan` it reads HCL → builds a dependency graph (subnet before NIC, NIC before VM — inferred from references) → refreshes state → diffs → emits the change set. `apply` walks that graph in order, calling Azure's ARM REST API per resource, then records what it created into `terraform.tfstate` (or `terraform.tfstate.d/<workspace>/` under workspaces).

The `azurerm_linux_virtual_machine` doesn't get its SSH key "inside" the VM by magic — Azure's VM provisioning agent (waagent) writes it to `/home/<user>/.ssh/authorized_keys` at first boot, same agent that runs the `custom_data` cloud-init. Which also explains my auth bug: `admin_ssh_key` accepts an empty string silently, Azure just provisions the user with *no* key — hence the validation guard now.

---

# Part 2 — GitHub Actions (pipeline owner)

## Step 1 — Purpose

The pipeline exists so a push to `main` turns into a tested, deployed release without anyone remembering steps — and so a broken or unhealthy release physically cannot reach production. The job DAG (`needs:`) plus the staging health gate plus the prod approval are the enforcement mechanism.

Actions because it lives in the repo: no extra service, free minutes, `GITHUB_TOKEN` authenticates to GHCR for free.

## Step 2 — Use

Real example: a merge to `main` ran test → built both Docker images → pushed them to GHCR tagged `ghcr.io/…-web:<sha>` and `…-server:<sha>` → SCP'd the deploy bundle to the staging VM → `docker compose pull && up -d` → curled `/health` and `/` until 200 → then sat at "Review deployments" until I clicked approve → deployed the same sha to prod. Total: ~6.5 minutes, zero SSH by hand.

## Step 3 — Versions

| Axis | Options | Used |
|---|---|---|
| Runner | GitHub-hosted / self-hosted | `ubuntu-latest` hosted |
| Deploy strategy | rolling / blue-green / canary | rolling (`compose up -d`) on one VM per env |
| Promotion | environments + reviewers / manual dispatch / tags | `environment: production` + required review |
| Registry | GHCR / Docker Hub / ACR | GHCR — same auth as the pipeline |

## Step 4 — Alternatives

| Alternative | Pick when | Why not |
|---|---|---|
| Jenkins | Complex orchestration, on-prem | Maintaining a server for a 5-job pipeline |
| GitLab CI | Repo on GitLab | Repo is on GitHub |
| ArgoCD / Flux | k8s fleet, GitOps pull model | One VM running compose |
| Manual SSH deploy | Hobby box | Unrepeatable — what we replaced |

## Step 5 — Limits

Named failures from this project:

- **Build-time secrets are easy to forget.** Both Dockerfiles mount `web_env`/`server_env` BuildKit secrets; the first run failed because `build-push-action` doesn't auto-provide them. Fix: write temp env files from secrets + `secret-files:`.
- **An empty env var beats a file.** Varlock failed the web build because `ARG NEXT_PUBLIC_SERVER_URL` unset → `ENV` set it to `""`, and process.env outranks `.env.local`. Fix: `build-args:` placeholder.
- **`scp-action` `rm: true` + `target: "~"` wipes the home directory** — including `.ssh/authorized_keys`, which then makes every subsequent SSH attempt fail with a misleading "key rejected" error. Fixed by dropping `rm` (scp overwrites anyway).
- **Health gates don't roll back.** A failed health check leaves the job red but possibly the new container running. Rollback stays manual via `workflow_dispatch` + sha — cheap only because images are sha-tagged and immutable.
- **Runner minutes and `ubuntu-latest` drift** — hosted runners are ephemeral and the label moves.
- **Approval gates need a public repo or paid plan** — private-repo free tier doesn't show "Required reviewers" (worked here after the repo setup; fallback was `workflow_dispatch`-only prod).

## Step 6 — Logs and observability

The Actions tab is the deploy history: each run shows the job DAG green/red, and every step expands to logs — the docker build output exposed the exact varlock failure, and the drone-scp output exposed the SSH auth failure. `appleboy/ssh-action` echoes the remote script's output so the health-check loop is visible in the job log itself.

Server side, the deploy step *is* an observability gate: it curls `localhost:3000/health` and `localhost:3001/` up to 12×5s and fails red otherwise — no 200, no approval prompt, no prod.

## Step 7 — Configuration

- `on: push [main]` full pipeline; `pull_request` test only; `workflow_dispatch` with `tag` input = the rollback lever.
- `permissions: contents:read + packages:write` — least privilege for `GITHUB_TOKEN`.
- `needs:` chains test → build → deploy-staging → deploy-prod.
- `environment: staging/production` — maps jobs to GitHub environments; `production` carries the reviewer gate.
- Secrets in Settings → Secrets: `DEPLOY_SSH_KEY`, `DATABASE_URL`, `GHCR_PAT` — never in the repo.
- Image tag = commit sha (`inputs.tag || github.sha`) — every release reproducible.

## Step 8 — Procedures

Deploy: merge to `main`, watch Actions, approve prod when it pauses.
Rollback: Actions → ci → Run workflow → `tag` = previous green sha → approve prod again.
Diagnose: open the red job → the failing step's logs show the real error (build output or remote script output).

## Step 9 — Internals

Each job gets a fresh ephemeral runner VM; nothing persists between jobs except files checked out and images in GHCR. `needs:` builds a DAG — a red upstream job marks dependents "skipped", which is the actual mechanism stopping bad code reaching VMs. `GITHUB_TOKEN` is minted per run, scoped by `permissions`, and dies with the run — that's how GHCR push works with no stored credential. Docker builds are multi-stage (builder compiles, runner ships `dist`) so images stay small; sha tags make them addressable forever.

---

# Part 3 — Prometheus + Grafana (observability owner)

## Step 1 — Purpose

Prometheus exists so the platform has a number for "is it healthy" instead of a guess — it scrapes the API's `/metrics` every 15s into a queryable time series. Grafana exists to make those numbers legible: one dashboard showing up/down, error rate, request rate and response time. Together they turn "customers report errors" into an alert with a name.

## Step 2 — Use

Real example: during the game-day rehearsal I injected `faultRate=1`; within ~90s `HighErrorRate` went pending → firing, the Grafana error-rate panel showed the 5xx spike, and the Firing Alerts panel named the alert. Deleting the fault cleared the alert ~20s later. That loop — inject, detect, name, clear — is exactly the demo the assignment asks for.

## Step 3 — Versions

| Piece | Options | Used |
|---|---|---|
| Metrics model | pull (Prometheus) / push (StatsD, pushgateway) | pull — API exposes `/metrics` |
| Instrumentation | `prom-client` (node) / OpenTelemetry | `@prometheus-io/client` |
| Alerting | Prometheus rules / Grafana managed alerts / Alertmanager | Prometheus `alerts.yml` rules |
| Dashboard | hand-built JSON / provisioning files / UI clicks | provisioned via `monitoring/grafana/` |

## Step 4 — Alternatives

| Alternative | Pick when | Why not |
|---|---|---|
| Grafana Cloud / Datadog | Managed, no self-hosting | Self-hosted is free, on-VM, and shows more platform work |
| Alertmanager + Slack | Team needs paging | Demo-scale; `/alerts` + dashboard is enough signal |
| OpenTelemetry collector | Multi-signal (traces+metrics) fleet | One API; prom-client is one dependency |
| Azure Monitor | All-Azure shop | Prometheus/Grafana is the assignment's named stack |

## Step 5 — Limits

- **Alerts only fire while traffic flows.** `rate(http_errors_total[5m])` needs errors *and* traffic — inject a fault on an idle API and the alert never trips (learned rehearsing: I had to generate requests).
- **`for:` adds detection latency by design.** `for: 30s` + 15s scrape + rate window ≈ 90s to firing. Shorter means noisier.
- **Liveness ≠ health.** `/health` stayed green while every tRPC call 500'd — an uptime check alone would have missed the fault entirely. The error-rate alert caught it.
- **Pull model can't see what it can't reach.** Prometheus down = silent blindness; in prod you'd alert on Prometheus itself.
- **Cardinality.** Labels like `route` are safe; high-cardinality labels (user IDs) would explode the time-series DB — kept the label set tiny on purpose.

## Step 6 — Logs and observability

Prometheus is self-observing: `:9090/targets` shows scrape health per job (`up`, last error), `:9090/rules` shows every rule's state and last evaluation, `:9090/alerts` shows pending/firing. Grafana's Firing Alerts panel queries `ALERTS{alertstate="firing"}` — the same metric Prometheus exposes for alert state. For the app itself: `docker compose logs -f server`, and `/metrics` raw text is curl-able for spot checks.

## Step 7 — Configuration

- `prometheus.yml` — `scrape_interval: 15s`, job `lumen-api` → `server:3000` (compose DNS), `rule_files: alerts.yml`.
- `alerts.yml` — three rules: `ApiDown` (`up==0`, 30s, critical), `HighErrorRate` (`rate(http_errors_total[5m])>0.1`, 30s, warning), `HighLatencyP95` (`histogram_quantile(0.95, …)>1`, 1m, warning).
- Grafana provisioning — `datasources/prometheus.yml` points at `http://prometheus:9090`; `dashboards/dashboards.yml` auto-loads `lumen.json` (five panels: status stat, firing alerts stat, request rate, error rate, p50/p95).
- Ports 9090/3002 opened in the NSG's `app_ports` variable — config is code all the way down.

## Step 8 — Procedures

Dashboard: `http://<env>:3002/d/lumen-api-overview`. Check scrape health: `:9090/targets`. Check alerts: `:9090/alerts`. Inject fault: `POST /__debug/fault {"rate":1}` → generate traffic → watch alert fire → `DELETE /__debug/fault`. Change a rule: edit `alerts.yml`, redeploy (the file is volume-mounted into the container).

## Step 9 — Internals

Prometheus is a pull-based time-series DB: every 15s it GETs `/metrics`, parses the text exposition format into samples `metric{labels}=value @ts`, stores them locally. `prom-client` inside the API maintains a `Histogram` (`http_request_duration_seconds`, buckets `[0.05…2.5]`) and a `Counter` (`http_errors_total`) incremented by Hono middleware per request. Rules evaluate PromQL over the stored series every `evaluation_interval`; an alert goes pending → firing once its `for:` duration elapses — the pending state is why there's a deliberate ~60s buffer before the notification. Grafana never stores metrics; it renders PromQL against Prometheus's HTTP API per panel.

---

# Part 4 — Secrets + rollback/runbook tooling (reliability & security owner)

## Step 1 — Purpose

This layer exists for two guarantees the rubric demands: secrets never live in the repository, and a bad release can be reversed within 10 minutes. The tools: GitHub Actions secrets + varlock env schemas on the secret side; sha-tagged images + `workflow_dispatch` + a runbook on the recovery side.

## Step 2 — Use

Real example: the pipeline writes `apps/server/.env` onto the VM at deploy time from `secrets.DATABASE_URL` — the Neon connection string exists in exactly two places (the repo secret store, and the VM's gitignored file) and nowhere in git history. For rollback: `Actions → ci → Run workflow → tag=<previous sha>` redeploys the prior release through the same health gate; measured under 10 minutes end to end.

## Step 3 — Versions

| Concern | Options | Used |
|---|---|---|
| Secret storage | repo secrets / env secrets / external vault | GitHub repo secrets (Vault = stretch, not needed) |
| Env validation | none / varlock schemas | `.env.schema` per app — build fails on missing vars |
| Rollback mechanism | image tags / blue-green / DB migrations+app rollback | sha-tagged images + dispatch |
| Recovery docs | tribal knowledge / runbook | `docs/runbook.md` — game day ran off it |

## Step 4 — Alternatives

| Alternative | Pick when | Why not |
|---|---|---|
| HashiCorp Vault | Multi-team secret rotation, dynamic creds | Stretch goal; Actions secrets cover a small project |
| Azure Key Vault | All-Azure estate | Extra identity plumbing for one connection string |
| `.env` committed (encrypted e.g. sops) | Want secrets in git but encrypted | Still a file to leak; secret store is cleaner |
| Blue-green rollback | Instant cutover needed | Doubles infra on a quota-limited trial sub |

## Step 5 — Limits

- **Secrets are invisible when wrong.** A bad `DEPLOY_SSH_KEY` produces only "unable to authenticate" — GitHub masks the value so you can't eyeball it. Debug required deriving the key fingerprint on the runner to prove the secret matched the file.
- **Gitignored ≠ gone.** `.env` files excluded by `.gitignore` still sit on disk and in the Docker build context — the Dockerfiles mount them as BuildKit secrets instead of copying, so they never land in image layers.
- **Rollback rolls forward.** `docker compose up -d` with the old tag is a new deployment — if the old image was purged or DB schema moved forward, "rollback" has edges. Neon schema is stable enough here to accept it.
- **Runbook rot.** Docs written before the last incident go stale — the `rm: true` footgun is in the runbook now precisely because it happened.
- **One shared DB across envs.** Staging and prod share Neon — a real deployment would branch the DB per env (documented trade-off).

## Step 6 — Logs and observability

Secret hygiene is verifiable: `git log --all -p | grep -i 'neon\|private key'` returns nothing; the repo's `.gitignore` excludes `.env*` and `terraform.tfstate*`; GitHub's secret masking means even accidental prints show `***`. Recovery ops are observable through the same monitoring stack — a rollback is just a deploy, so it's visible in the Actions log and on the dashboard.

## Step 7 — Configuration

- `DEPLOY_SSH_KEY` — ed25519 private key, VM-authorized via `az vm run-command` / Terraform `admin_ssh_key`.
- `DATABASE_URL` — Neon connection string → written to `apps/server/.env` on the VM.
- `GHCR_PAT` — `read:packages` PAT so VMs can `docker pull` private images.
- `GITHUB_TOKEN` — auto-issued, scopes down by `permissions:`.
- Image build placeholders — `NEXT_PUBLIC_SERVER_URL=http://localhost:3000` etc. exist only to satisfy varlock at build; real values are runtime.

## Step 8 — Procedures

Roll back: Actions → ci → Run workflow → `tag` = previous sha → approve prod. Emergency on-box: `cd ~/deploy/lumen-health && IMAGE_TAG=<sha> docker compose pull && docker compose up -d`. Rotate the deploy key: generate new pair → `az vm run-command` install pub key → update GitHub secret → rerun deploy. Game day: follow `docs/runbook.md` §4; record timings in `docs/game-day.md`.

## Step 9 — Internals

GitHub secrets are encrypted at rest and injected as env vars only into jobs that reference them — they're masked in logs by string replacement, which is why a leaked-but-masked value shows `***` and why "wrong secret" surfaces as a downstream auth error rather than a secret error. Immutability does the rollback work: a sha-tagged image is content-addressed, so "redeploy sha X" is a pull-by-identity, not a rebuild — nothing about the artifact can have changed since it last ran. The health gate closes the loop: rollback and deploy verify with the same curl contract, so "recovered" is machine-checked, not vibes.
