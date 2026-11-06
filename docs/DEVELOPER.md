# kingdoms-infra — developer guide

`kingdoms-infra` holds the infrastructure of the Kingdoms Discord bot
platform: Docker environments, CI/CD workflows, GitOps manifests and the
deployment scripts executed on the VPS runners.

Read the shared
[conventions](https://github.com/merlin-pinpin-org/kingdoms/blob/main/docs/CONVENTIONS.md)
and the
[operating model](https://github.com/merlin-pinpin-org/kingdoms/blob/main/docs/VIBEWORKFLOW.md)
in the `kingdoms` repo. This page covers what is specific to working *in
this repo*.

## Layout

| Path | Content |
| ---- | ------- |
| `AGENTS.md` | Short agent entry point (points here) |
| `envs/<env>/` | One directory per environment: `docker-compose.yml` + `state/` (the pinned state files synced to the `deploy/<env>` branch) |
| `deploy/<env>/` | Protected state branches (one per environment) pinning the image and deploy metadata — the GitOps source of truth (ADR-0018) |
| `.github/workflows/` | CI checks + the deploy chain (`deploy.yml` routing + re-pin job, `deploy-env.yml` reusable per-env deploy, `pin-state.yml`, `sync-state.yml`) |
| `scripts/` | `deploy.sh` (idempotent, health-gated), `restore_db.sh`, backup scripts, `diagnose_deploy.sh` (stuck-deploy diagnosis) |
| `Makefile` | `make check` (script syntax + compose config), `make doctor` (deploy health per env), `make diagnose-deploy-<env>` |
| `docs/` | [ENVIRONMENTS.md](ENVIRONMENTS.md), [GITOPS.md](GITOPS.md), [DEPLOYMENT.md](DEPLOYMENT.md), [VPS-SETUP.md](VPS-SETUP.md) |

## Environments are data

An environment is defined by four pieces, all data — no per-env workflow:

- a directory `envs/<env>/` (compose manifest + `state/`),
- a state branch `deploy/<env>` (protected),
- a runner with the label `env-<env>`,
- a GitHub environment `<env>` (with its reviewers/protection).

Adding an environment = creating the directory, the branch, the runner and
the GitHub environment; the workflows pick it up automatically. `prod` is
protected (`PROTECTED_ENVS`): PR deploys never target it; only released
`vX.Y.Z` images are pinned there. See
[ENVIRONMENTS.md](ENVIRONMENTS.md).

**Pre-1.0 directions (developer, 2026-11-06 session):** the durable data
stores (MongoDB, Redis) move to the managed external clusters — the
compose stops carrying them in test and prod, the daily dump targets the
clusters and a restore drill is rehearsed (issue #127); and the bot
scales to **N bot containers from the same image** (at least 3 in test
and prod), each loading its mod set from a `KINGDOMS_MODS` environment
variable — the environment model above stays unchanged, only the number
of bot services per env grows.

## Checks

Anyone can run the local checks with a public clone, no credentials:

```bash
bash -n scripts/*.sh
shellcheck scripts/*.sh   # if available
docker compose -f envs/test/docker-compose.yml config
```

Run `bash -n` (and shellcheck when available) on every script before
pushing. Anything that cannot run in the dev sandbox (Compose boot, stack
healthchecks, backup/restore round-trips, entrypoint runs) is exercised by
the CI workflows instead.

## Deploy chain (summary)

1. `/deploy [env]` on a `kingdoms-services` PR (or a release) dispatches
   `pin-state` with the image and deploy metadata.
2. `pin-state.yml` merges `main` into `deploy/<env>` and writes the pin
   (`envs/<env>/state/kingdoms-bot.yml`) atomically (single-writer
   concurrency `deploy-state-<env>`, ADR-0018).
3. The push triggers `deploy.yml` → `deploy-env.yml`, which runs on the
   `env-<env>` self-hosted runner, applies the pinned state with
   `scripts/deploy.sh` and gates on health.
4. `sync-state.yml` propagates `main` to the state branches; config changes
   on `main` redeploy the env **at its current pin** — the image (release,
   pre-release or PR) is never swapped by a config change, only the
   manifests move (`prod` is never touched by this path).

Deployment is **GitOps-driven**: changes to the state branches are applied
by CI/CD, never by hand on the VPS. Deploy scripts must stay idempotent and
support rollback (`deploy.sh`, database restore via `restore_db.sh`).

## Workflow pitfalls (learned the hard way) — this repo's troubleshooting section

The binding policy lives in kingdoms CONVENTIONS.md, *Troubleshooting
is part of the fix*: every fixed incident ships its regression check
and a dated entry here (symptom → root cause → fix → the check that
guards it), newest first.

- **Never rename a workflow or a workflow job that backs a required status
  check.** GitHub rulesets match check contexts by **exact name**: the
  rename in #77 (`Lint scripts and shell files` → `Lint scripts and
  workflows`) left all three rulesets waiting for a check that never
  reports, silently blocking every merge — caught on #81, fixed by #82 and
  the live ruleset update (2026-09-26). The repo-side audit cannot catch
  this: the rename PR passes its own checks while the ruleset still expects
  the old name. A rename therefore requires the three changes in one PR:
  job rename + docs/audit list update + live ruleset update (admin, web UI) —
  and if you must rename, update the rulesets first, merge the rename
  second. When in doubt: don't rename, add the extra step to the existing
  job instead.
- A required status check never uses a `paths:` filter — it must report on
  every PR (fixed for `check-infra.yml`; applies to every workflow backing
  a required check).
- `paths:` filters on the deploy chain must include `scripts/deploy.sh`
  and the workflow files themselves, or a merge triggers no deploy.
- Dynamic `runs-on` needs
  `fromJSON(format('[\"self-hosted\", \"kingdoms\", \"env-{0}\"]', inputs.environment))`
  — `format()` alone yields a string, which becomes one literal label.
- Reusable workflows cannot elevate permissions: the caller grants
  `packages: read`.
- Deploy runs use the workflow file **from the state branch** — fixes to
  the deploy chain need sync propagation to take effect.
- `client_payload` of `repository_dispatch` is capped at 10 properties.

## A deploy stays pending: the concurrency-zombie trap (2026-09-24 prod incident)

A run left `waiting` (environment approval) **acquires the
`deploy-<env>` concurrency group immediately**, and with
`cancel-in-progress: false` it holds it forever — every newer run stays
`pending` with **no deployment status, no notification, and the runner is
never asked** (`runner_name: null` on the job). Worse: the zombie may run
an **older or deleted workflow version** (labels baked at run creation), so
fixing the workflow file does not unblock it.

Symptoms, in order of probability:

1. Newer deploy runs `pending`, `steps: []`, `runner_name: null`, and the
   deployment object has **no statuses at all** (not even `waiting`) →
   check for a stale `waiting`/`pending` run on the same state branch:
   it holds the concurrency group.
2. The run is `waiting` with a **pending deployment** → environment
   approval (required reviewers); GitHub notifies through the review
   banner, not the usual run events.
3. The deploy job is queued and `labels` shows one comma-joined string
   (`self-hosted,kingdoms,env-prod`) → pre-`fromJSON` bug: no runner will
   ever match; cancel the run.
4. Everything green on GitHub but nothing on the VPS → runner offline
   (`sudo ./svc.sh status`, VPS-SETUP troubleshooting).

Run `make doctor` or `make diagnose-deploy-<env>`
(`scripts/diagnose_deploy.sh <env>`, `--json` for agents) — it walks these
causes in order, links every stale run to cancel, and exits 1 when
something blocks. **Diagnose before touching the runner**: in the 2026-09-24
incident the runner was healthy and idle the whole time.

Queued runs of **deleted workflows** (e.g. the old `deploy-test.yml`) never
start and hold no concurrency group — advisory cleanup only: cancel them
from the run page.

## Keeping docs in sync

Any infrastructure change must be reflected in the `kingdoms` documentation
(source of truth) before merge, and in this repo's own `docs/` pages
(ENVIRONMENTS, GITOPS, DEPLOYMENT) when they describe the changed behavior.
