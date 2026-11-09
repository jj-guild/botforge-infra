# Deploy GitHub App setup (one-time)

`/deploy` (a PR comment on `botforge-services`) must trigger the
**Pin state** workflow of this repository. GitHub Actions cannot listen to
another repository's events, so the trigger crosses repositories; it does so
with a **GitHub App** instead of a permanent personal access token:

- the app is installed on **`jj-guild/botforge-infra` only**;
- it holds two permissions: **Actions: write** and **Contents: write**
  (ADR-0018: it pins the deployed image in the `deploy/<env>` state
  branches; it still cannot read secrets, comment, or touch `main`);
- the workflow in `botforge-services` mints an **ephemeral token** from it
  (valid for at most one hour, `actions/create-github-app-token@v3`), so no
  permanent credential ever leaves GitHub;
- `deploy.yml` exposes its `workflow_dispatch` trigger to the allowed
  actors only, so the app is structurally unable to reach `prod`;
- workflow execution rulesets (see below) restrict who may dispatch
  `deploy.yml`, so the app is the *only* actor that may trigger it
  on demand.

## 1. Create the app

As the developer (Settings → Developer settings → [New GitHub App](https://github.com/settings/apps/new)):

| Field | Value |
| --- | --- |
| GitHub App name | `jj-guild-deployer` |
| Homepage URL | `https://github.com/jj-guild/botforge` |
| **Repository permissions** | **Actions: Read and write** + **Contents: Read and write** (state-branch commits, ADR-0018) |
| Where can this app be installed | **Only on this account** |

No webhook, no user permissions, no other repository permission.

On the app page, scroll down to the **Private keys** section and click
**Generate a private key**: a `.pem` file downloads immediately. GitHub
keeps only the public half — the private key **cannot be downloaded again**;
if you lose it, generate a new one (and update the secret below). Do not
confuse it with the *client secret*, which serves the OAuth user flow and
is not used here.

## 2. Install it on botforge-infra only

Install the app (`jj-guild-deployer`) on `jj-guild/botforge-infra`
only — leave every other repository unchecked, especially
`botforge-services` and `botforge`.

## 3. Store its credentials on botforge-services

On `jj-guild/botforge-services` (Settings → Secrets and variables →
Actions → New repository secret), add:

| Secret | Value |
| --- | --- |
| `BOTFORGE_DEPLOYER_APP_ID` | The App ID shown on the app's page |
| `BOTFORGE_DEPLOYER_APP_PRIVATE_KEY` | The `.pem` private key (download it when generated; the full file content, including the BEGIN/END lines) |

The `Deploy PR (comment)` workflow of `botforge-services` reads these
two secrets. The **re-pin job** of this repository's Deploy environment workflow
(a config change on `main` re-pins the state of non-protected
environments) needs the same credentials on `botforge-infra`: add `BOTFORGE_DEPLOYER_APP_ID` and
`BOTFORGE_DEPLOYER_APP_PRIVATE_KEY` as repository secrets of
`botforge-infra` too (Settings → Secrets and variables → Actions).

Once the app is installed with Contents: write and the secrets set,
`/deploy` comments on PRs of `botforge-services` dispatch the
[Pin state](../.github/workflows/pin-state.yml) workflow of this repository
(`repository_dispatch`, `pin-state`): it pins the PR image in the
`deploy/<env>` state branch — merging `main` in the same commit — and the
state push deploys it to the test hosting. All writers to a state branch share
the `deploy-state-<env>` concurrency group (single-writer design, see
docs/ENVIRONMENTS.md § "Keeping the state branches current").

## 4. Restrict who may trigger the deploy chain (recommended)

GitHub [workflow execution protections](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/actions-policies/workflow-execution-protections)
are built on the rulesets framework: they define, **before a run starts**,
which actors may trigger which workflows. This step is **defense-in-depth**:
the app already cannot do anything but dispatch `deploy.yml` (single
permission, single repository, and the prod workflow is not dispatchable).
Without a policy, anyone with write access can still trigger the workflow
manually from the Actions tab.

> **Prerequisite unblocked (2026-09):** third-party GitHub Apps can only be
> added to actor allow lists **when the repository belongs to an
> organization**. The repositories moved from the personal account
> `merlin-pinpin` to the `jj-guild` organization, and the app has
> since recorded activity here (it dispatched the Pin state run), so the
> actor picker now lists `jj-guild-deployer[bot]`. On the personal-account
> repository the picker did not list the app and this policy was deferred
> — this note records why.

To add the policy, on `jj-guild/botforge-infra` (Settings →
Actions → Policies → New policy):

- **Name**: `deploy-test-dispatch`;
- **Target**: the workflow `.github/workflows/deploy.yml`;
- **Actor rule** (allow list): **`jj-guild-deployer[bot]`** only — add the
  human administrators too if they want a manual fallback (otherwise
  nobody can dispatch the workflow by hand);
- **Event rule** (allow list): `workflow_dispatch` and `push` — `push`
  keeps the test-config-change deploys on `main` working.

Result: only the app can dispatch **Deploy environment** on demand; the
test-config-change deploys (push on `main`) keep working; no other human
or bot can trigger the workflow directly.

Order matters: enable this policy only **after** a first successful
`/deploy` (so the app has recorded activity and appears in the
picker), then run a second `/deploy` to verify the flow still passes —
the app is the actor of the dispatch, so an actor allow list without the
app would break `/deploy` entirely.

> **The actor picker may still not list the app.** The UI picker
> (checked 2026-09, on an organization repository, with the app having
> recorded dispatch activity) does not offer third-party GitHub Apps in
> the allowed-actors list — only users, repository roles, and
> GitHub-owned bots. If it does not list `jj-guild-deployer[bot]`, create
> or edit the policy through the **REST API** instead of the UI, which
> accepts bot identities by ID:
>
> ```bash
> # Bot id: jj-guild-deployer[bot] = 332499271
> gh api --method POST /repos/jj-guild/botforge-infra/actions/policies \
>   -f name=deploy-test-dispatch \
>   -f enforcement=active \
>   -f workflow_path=.github/workflows/deploy.yml \
>   -F 'allowed_actors[][id]=332499271' -F 'allowed_actors[][type]=Bot' \
>   -F 'allowed_events[]=workflow_dispatch' -F 'allowed_events[]=push'
> ```
>
> Then verify with a `/deploy`: the run must still be created by
> `jj-guild-deployer[bot]` — an actor list without the app breaks the
> `/deploy` flow. To adjust the policy later, use
> `gh api /repos/jj-guild/botforge-infra/actions/policies` to list
> the policy ids and the update endpoint on the same API.
> The exact body-parameter names are documented in the
> [Actions policies REST API](https://docs.github.com/en/rest/actions/policies)
> — check them against the running `gh`/API version before running the
> command, and fall back to the UI with the repository-admin role if a
> parameter is rejected.

## 5. Grant botforge-infra access to the bot image package

The bot image package `ghcr.io/jj-guild/botforge-services` is
owned by the **botforge-services** repository (its Docker workflow
publishes it). It is not public, and after the organization transfer a
package's access no longer extends to the other repositories: the
deploy job pulling it from the test hosting fails with
`error from registry: unauthorized`.

Two halves, both required:

- **Package side (GitHub UI, org owner):** on
  [the package settings](https://github.com/orgs/jj-guild/packages/container/package/botforge-services/settings),
  **Manage Actions access** → *Add repository* → `botforge-infra` → role
  **Read** (pull only; the repo never pushes to this package). Do the
  same for the `botforge` repo only if a workflow there ever needs to
  pull the image.
- **Workflow side (in this repository):** `deploy.yml` logs in to ghcr.io with the job's `GITHUB_TOKEN`
  (`permissions: packages: read`) before running `scripts/deploy.sh`,
  so the pull from the hosting is authenticated as this repository.

Without the package-side grant the token is not enough: GHCR checks
repository access on the package. Without the login step the pull is
anonymous and fails closed.

## Verify

1. Comment `/deploy` on any PR of `botforge-services`.
2. The PR gets a 🚀 comment, then a ✅ one.
3. A **Pin state** run followed by a **Deploy environment** run appear in
   this repository's Actions (triggered by `jj-guild-deployer[bot]`),
   run on the self-hosted runner, and the bot on the test hosting restarts
   with the PR image.
