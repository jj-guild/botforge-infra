# GitOps

The BotForge infrastructure follows GitOps principles: the desired state of
every environment is described by versioned files in this repository, and
the deployed state converges to them through automation.

## Principles

1. **Declarative**: each environment is fully described by its compose
   manifest in `envs/<env>/` and its documented variables.
2. **Versioned and immutable**: every environment change goes through a pull
   request; the manifests reviewed are the manifests applied.
3. **Pulled automatically**: the deploy chain
   (`deploy.yml` routing → `deploy-env.yml` per-environment deploy) applies
   the pinned state after the state-branch push, executed by a
   self-hosted runner on the VPS (see [VPS-SETUP.md](VPS-SETUP.md)) —
   nobody applies changes by hand.
4. **Continuously reconciled**: `scripts/deploy.sh` is idempotent; re-running
   it converges the environment to the manifest state.
5. **Verified after apply** (botforge-infra#78): the post-deploy battery
   reads the pinned state from the state file and confirms the running
   deployment matches it — a confirmed mismatch rolls back
   automatically, an inconclusive check reports only, and the
   behavioral journeys run off-VPS at the pinned commit.

## Workflow

```mermaid
flowchart LR
    PR["Pull request touching envs/"] --> REVIEW["Developer review"]
    REVIEW --> MERGE["Merge to main"]
    MERGE --> CI["CI: shellcheck, compose validation, smoke, backup/restore round-trip"]
    CI --> CD["CD: apply manifests to the target environment"]
    CD --> BACKUP["Mandatory pre-deploy backup"]
    BACKUP --> GATE["Post-deploy health gate"]
    GATE -->|"healthy"| BATTERY["Post-deploy battery (identity + registration)"]
    GATE -->|"unhealthy"| ROLLBACK["Automatic rollback"]
    BATTERY -->|"confirmed P0 (wrong identity)"| ROLLBACK
    BATTERY -->|"confirmed / P2 findings reported"| STACK["Bot + MongoDB + Redis"]
    BATTERY --> JOURNEYS["SimCord journeys on the pinned commit (GitHub-hosted, non-gating)"]
    ROLLBACK --> STACK
```

1. A change to `envs/` or `scripts/` opens a PR; the
   `Check infra` and `CI` workflows validate it.
2. After merge to `main`, `CD` applies the new state.
3. Secrets are injected at deploy time by the self-hosted runner from the
   GitHub environment secrets; they never live in the repository or on
   the VPS.

## Rollback

Because state is versioned, rollback is a git operation: revert the **pin
commit on the state branch** and the push re-triggers the pipeline, which
re-applies the previous image. A failed deployment never reverts code on
`main` and never touches another repository — the state is the only
rollback surface. Data-level rollback (schema changes) uses the database
backups — every deployment produces one *before* touching the stack, and
`scripts/rollback.sh --auto` restores the latest one when the state revert
is unavailable (prod requires an approved PR for every state push, by
design). The CI job `Backup/restore round-trip test` continuously verifies
that a backup can be restored byte-for-byte.
