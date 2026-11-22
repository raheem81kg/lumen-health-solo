# Game Day — Injected API Failure

**Date:** 2026-11-19
**Environment:** staging (`lumen-staging2.eastus.cloudapp.azure.com`)
**Operator:** Raheem
**Doc used:** `docs/runbook.md` only — no prior knowledge of the fault.

## Scenario

The operator was told only: *"the API seems broken — customers report errors."*
The actual fault: `POST /__debug/fault {"rate": 1}` was armed on the API,
making every tRPC request return HTTP 500 (a simulated bad release).

## What "broke"

- Every call to `/trpc/*` returned `500 {"error":"injected fault"}`
- The web app loaded but tasks data failed to fetch
- `/health` stayed green — the process was alive, only traffic was failing
  (deliberately sneaky: an uptime check alone would not catch this)

## Timeline

| Time | Event |
|---|---|
| 15:49:00 | Fault injected (`faultRate = 1`), traffic flowing |
| 15:49:47 | First 500s visible in Error Rate panel |
| 15:50:44 | `HighErrorRate` enters **pending** (Prometheus evaluation) |
| 15:51:14 | `HighErrorRate` **firing** — visible on `/alerts` and dashboard |
| 15:54:00 | Operator checks runbook §3 → runs the fault-check curl → sees `faultRate: 1` |
| 15:54:20 | `DELETE /__debug/fault` → `faultRate: 0` |
| 15:54:40 | Traffic resumes 200s; alert resolves |

**Time to notice:** ~90 seconds (first alert signal after fault injection)
**Time to recover:** ~20 seconds (clear fault → healthy responses → alert resolved)

## Detection path (how it was actually found)

1. Grafana dashboard **Firing Alerts** panel showed `HighErrorRate`
2. **Error Rate** panel showed a 5xx spike starting 15:49 — while Request
   Rate stayed normal and API Status stayed UP
3. Runbook §3 `HighErrorRate` → run the fault-check curl → `faultRate: 1`
   identifies it as an injected fault, not a code regression → clear, not rollback

If this had been a real bad release instead, the same alert path leads to
runbook §2 (rollback via workflow_dispatch + previous sha).

## Evidence

- `docs/evidence/screenshot-alert-HighErrorRate.png` — Prometheus `/alerts`
  with `HighErrorRate` in FIRING state
- `docs/evidence/screenshot-dashboard-error-spike.png` — Grafana dashboard
  showing the 5xx spike + firing alert panel

## Lessons

- `/health` liveness ≠ traffic health — we needed the error-rate alert to
  catch a fault that returns fast 500s but never crashes the process.
- The `for: 30s` on the alert means ~90s total detection latency
  (scrape interval + rate window + pending duration). Acceptable for demo;
  shorter `for:` would notice faster but risk flapping.
- `rm: true` on the scp deploy step previously wiped the deploy user's
  `~/.ssh`, breaking SSH — fixed in CI; documented so nobody re-adds it.
