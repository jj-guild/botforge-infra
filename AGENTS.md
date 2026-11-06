# AGENTS.md

`kingdoms-infra` — Docker, CI/CD, GitOps manifests and deployment scripts
for the Kingdoms Discord bot platform.

## Read first

- [kingdoms/docs/CONVENTIONS.md](https://github.com/merlin-pinpin-org/kingdoms/blob/main/docs/CONVENTIONS.md)
  — conventions shared by the three repositories (language,
  humans-never-code, secrets, PR lifecycle, issues, checks).
- [kingdoms/docs/VIBEWORKFLOW.md](https://github.com/merlin-pinpin-org/kingdoms/blob/main/docs/VIBEWORKFLOW.md)
  — operating model (roles, session loop, approvals).
- [docs/DEVELOPER.md](docs/DEVELOPER.md) — this repo's layout, environment
  model, checks, deploy chain, workflow pitfalls.

## Repositories

- `kingdoms` (documentation, source of truth)
- `kingdoms-services`: core, Discord platform, mods, YAML configs
- `kingdoms-infra` (this repo): Docker, CI/CD, GitOps, deploy scripts

## Local rules

- Deployment is **GitOps-driven**: state branches are applied by CI/CD,
  never by hand on the VPS; deploy scripts stay idempotent with rollback.
- Ops manage environments and secrets in the GitHub web UI only; the agent
  never handles secret values.
- Verify scripts with `bash -n` and shellcheck (if available) before
  pushing; sandbox-limited checks are covered by CI workflows.
- **Never rename a workflow or a workflow job backing a required status
  check** — GitHub matches check contexts by exact name, so a rename
  silently blocks merges (see DEVELOPER.md, *Workflow pitfalls*).
- Any infrastructure change is reflected in the `kingdoms` docs (source
  of truth) before merge.
- **Enrich the docs and skills proactively** (developer-mandated): when
  the session's work teaches a rule, pitfall or pattern, update the
  matching skill page, convention or AGENTS.md entry as part of the
  change — see the kingdoms CONVENTIONS.md
  (*Documentation is part of the change*).
- Issue templates: `## Objective` / `## Context` / `## Specifications` /
  `## Acceptance criteria` / `## Dependencies` (blank issues disabled).
- **Issue references** are GitHub autolinks: same-repo `#N`, cross-repo
  `owner/repo#N` (e.g. `merlin-pinpin-org/kingdoms-services#52`) — a bare
  `repo#N` renders as plain text; never write it. See CONVENTIONS.md,
  *Documentation is part of the change*.
- **Automation mandate:** no one-off commands, for humans or sessions —
  every recurring operation is a committed Makefile target, script or
  workflow, and a useful improvised command is committed ("learned").
  Humans on GitHub only merge PRs and approve prod deploys
  (+ one-time bootstrapping) — see the kingdoms
  [Automate or learn](https://github.com/merlin-pinpin-org/kingdoms/blob/main/.agents/skills/automate-or-learn/SKILL.md)
  skill and CONVENTIONS.md (*Human GitHub scope*, *Everything is
  automation*).
- **PR merges, cowboy mode, branch cleanup and user-branch rules are
  defined once in the kingdoms CONVENTIONS.md** (single source of
  truth, all three repos): see
  [kingdoms/docs/CONVENTIONS.md](https://github.com/merlin-pinpin-org/kingdoms/blob/main/docs/CONVENTIONS.md)
  — *Cowboy mode* (API-blocked merges, maintainer-only direct pushes
  with per-push confirmation, never force-push `main`) and
  *Integration branches* (never delete `vibe/<alias>/main`).