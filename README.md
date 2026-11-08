# botforge-infra

Infrastructure as code for the BotForge Discord bot platform: Docker
images, Docker Compose environments, CI/CD workflows, GitOps manifests and
deployment scripts.

## Related repositories

- [botforge](https://github.com/jj-guild/botforge) — source of truth:
  architecture, ADRs, roadmap, mods documentation
- [botforge-services](https://github.com/jj-guild/botforge-services) —
  all Python code (generic core, Discord platform, mods, YAML configs)

## Layout

| Path | Content |
| ---- | ------- |
| `envs/<env>/` | One directory per environment: `docker-compose.yml` + `state/` (the pinned state files synced to the `deploy/<env>` branch) |
| `deploy/<env>/` | Protected state branches (one per environment) pinning the image and deploy metadata — the GitOps source of truth (ADR-0018) |
| `.github/workflows/` | CI checks + the deploy chain (`deploy.yml` routing, `deploy-env.yml` reusable per-env deploy, `pin-state.yml`, `sync-state.yml`) |
| `scripts/` | `deploy.sh` (idempotent, health-gated), backup/restore scripts, `diagnose_deploy.sh` (stuck-deploy diagnosis) |
| `Makefile` | `make check` (script syntax + compose config), `make doctor` (deploy health per env), `make diagnose-deploy-<env>` |
| `docs/` | Deployment, environments, GitOps and VPS setup guides |

## Local development

Prerequisites: Docker and Docker Compose, and `gh` for the diagnose targets.

```bash
DISCORD_TOKEN=... docker compose -f envs/test/docker-compose.yml up -d
```

This starts the bot (serving `/healthz`), MongoDB and Redis. See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)
for the full deployment guide and [docs/ENVIRONMENTS.md](docs/ENVIRONMENTS.md)
for the environment matrix.

## Deployment overview

Deployment is GitOps-driven: environments are data — a directory under
`envs/`, a `deploy/<env>` state branch, a runner labeled `env-<env>` and
a GitHub environment with its reviewers. One reusable workflow deploys
every environment: a push to a `deploy/<env>` state branch (the pinned
image) triggers the deploy, executed by the environment's **self-hosted
runner installed on the VPS** — never applied by hand. `test` is deployed
by PR comments (`/deploy`) and release validation pins; `prod` runs
released `vX.Y.Z` images only and waits for the environment's required
reviewers. See [docs/GITOPS.md](docs/GITOPS.md) for the model,
[docs/VPS-SETUP.md](docs/VPS-SETUP.md) for the complete server
installation guide (step by step, no Linux knowledge required), and
[docs/RUNNER.md](docs/RUNNER.md) for the one-page runner install /
uninstall cheat-sheet.

### A deploy is stuck?

Run `make doctor` (or `make diagnose-deploy-<env>`) **before checking the
runner**: it walks the blocking causes in order — stale runs holding the
`deploy-<env>` concurrency group, pending environment approval, broken
`runs-on` labels — and prints the exact fix with links. Read-only; agent
sessions get the same via `scripts/diagnose_deploy.sh <env> --json`.

## Contributing

You do not need an AI agent to contribute: see
[CONTRIBUTING.md](CONTRIBUTING.md) for the human path (clone, checks,
PR), [docs/DEVELOPER.md](docs/DEVELOPER.md) for the developer guide
(environment model, checks, deploy chain) and [AGENTS.md](AGENTS.md) for
the agent entry points. Every infrastructure change must be reflected in
the `botforge` documentation before merge.
