# .github

Org-wide defaults and shared checks for every PlantechHubDev repo.

## What lives here

**Org defaults.** GitHub applies the files under `.github/` to any repo that has none of its own:

- `pull_request_template.md`: the PR description every repo uses.
- `ISSUE_TEMPLATE/`: Bug, Feature and Task, matching the org's issue types.

**Why one place.** Issues and PRs read the same way in every repo, so triage and review don't depend on which repo you are in, and a template changes once instead of per repo. Repos therefore don't keep their own issue templates; conventions are in the engineering handbook (`workflow.md`).

**Shared checks, hooks and build workflows.**

| Path | What it is |
|---|---|
| `.github/workflows/checks.yml` | Reusable workflow every repo's `ci.yml` calls. Jobs: `secret-scan` (gitleaks over the push or PR range, `--redact`) and `commit-lint` (branch-name rule, then `hooks/check-commit-msg.sh` over the PR's commits; PRs from this repo's own `develop`, `master`, `main`, `test` or `demo` and Dependabot PRs skip it, while a fork's branch of those names is linted). |
| `hooks/check-commit-msg.sh` | The commit standard: `<type>(<scope>)!: <description>` plus a `Refs:` trailer. Hook mode (`<msg-file>`) and CI mode (`--range <base>..<head>`). The same script runs locally and in CI, so the two can't drift. |
| `hooks/add-issue-ref.sh` | `prepare-commit-msg` hook: on `<type>/<issue>-<slug>` branches, appends `Refs: #<issue>` when the message has none. |
| `.pre-commit-hooks.yaml` | Publishes the two hooks (`add-issue-ref`, `check-commit-msg`) for the [pre-commit](https://pre-commit.com) framework. |
| `.pre-commit-config.yaml`, `.gitleaks.toml` | This repo's own hooks and gitleaks config. Every repo has the same two files. |
| `.github/workflows/java-service-ci.yml` | Reusable build for a java service. On `merge_group` the diff-cover gate is skipped (the ratchet still runs). Jobs: `test` (no committed `mavenLocal()`, then Gradle `clean build`; skipped on Dependabot runs) and `image-scan` (image built from `test`'s jar, Trivy CRITICAL/HIGH with `.trivyignore`). Inputs `service`, `java-version`, `mysql-test-image`, `pact-fetch-consumers`, `pact-gate-providers`; secret `PUBLISH_TOKEN`. |
| `.github/workflows/java-service-publish.yml` | Reusable publish for a java service. Job `build-push`: Gradle `clean build`, then a linux/amd64 + linux/arm64 image to ECR only, tagged `:<branch>` and `:sha-<7>`, through OIDC. Inputs `service`, `java-version`, `ecr-role-arn` (pass `vars.ECR_PUSH_ROLE_ARN`), `mysql-test-image`; secrets `PUBLISH_TOKEN`, optional `TEAMS_WEBHOOK_URI`. |
| `.github/workflows/java-service-image.yml` | Reusable queue image for a trunk java service: builds the exact merge-queue commit and pushes it to ECR as `:sha-<7>` through OIDC. Jobs `check` (finds an existing image), `build` (Gradle with no AWS credentials, then push), `result`. Output `digest` (`sha256:<64 hex>`); callers `needs` the workflow job and read its `digest`. Inputs `service-name`, `role-to-assume` (pass `vars.ECR_PUSH_ROLE_ARN`), `checks-ref`, `java-version`, `mysql-test-image`; secret `packages-read-token`. |
| `.github/workflows/pth-sim.yml` | Reusable prod simulation in the merge queue: the full platform-tests suite on the queue image, on the self-hosted `pth-test` runner. Job `pth-sim`: runs only on `merge_group` (job-level `if`), fails before any checkout unless `checks-ref` is a release tag `vX.Y.Z`, and times out at 90 minutes (the queue's check timeout is 180). The org runner group restricts the runner to this workflow at a tag. Inputs `service-name`, `digest`, `checks-ref`. Work is in `scripts/pth-sim.sh`, which exits 5 without simulating when the queue entry's branch is gone. The runner's environment sets the environment details (see "Trunk repos" below). |
| `.github/workflows/java-service-release.yml` | Reusable release for a trunk java service, on the caller's push to `master` (pth-context platform-ops decision 0126). Nothing is rebuilt and no infrastructure PR is opened: the job (environment `prod`, `us-east-1`) runs, each step only if the one before succeeded: the inputs (`checks-ref` MUST be a release tag `vX.Y.Z`), the tip check (`scripts/release-is-tip.sh`: the commit is still the tip of `master`, so re-running an old release never rolls prod back; usually a newer merge landed first and its release deploys the change too), the green gate (`scripts/queue-run-green.sh`: the `merge_group` run of `ci-workflow` for exactly the merged commit concluded `success`, with `ci-ok`, `image` and `pth-sim` passed and no job failed or cancelled), then `scripts/release-image.sh` (the guard reads the running prod service's task definition, the source of truth: its image MUST be `<registry>/<service-name>:master`, else exit 3 with no AWS write; `sha-<7>` missing exits 2; the digest `:master` named before is kept as the previous image; then `sha-<7>` is retagged `master`), `scripts/ecs-deploy.sh` (force a new deployment, wait for `services-stable`), `scripts/post-deploy-checks.sh` (every running task on the retagged digest or a child manifest of its index, deployment `COMPLETED` at desired count, no `ERROR` line in the new deployment's awslogs streams, running or stopped tasks, since the deploy; at least one alarm named `alarm-prefix*` and none in `ALARM`) and `scripts/deploy-comment.sh` (the change record: a comment on the merge's own PR and every PR since the commit of the last successful run of this release workflow on `master`, so a release that carries several merges, or a re-run, drops none; once per deploy through a hidden marker; no PR, or a lookup error, fails the run). Every gate runs before `:master` moves; a failure after the retag fails the run loudly, and recovery is a revert PR through the queue. Inputs `service-name`, `role-to-assume` (the deploy role), `checks-ref`, `ci-workflow`, `ecs-cluster`, `ecs-service`, `log-group` and `alarm-prefix`, all required, from variables. No secrets: the caller's `GITHUB_TOKEN` only (`contents: read`, `id-token: write`, `actions: read`, `pull-requests: write`). |
| `.github/workflows/java-library-ci.yml` | Reusable build for a java library. Job `test` (no committed `mavenLocal()`, then Gradle `clean build`; skipped on Dependabot runs). No `version-check` from v2.0.0: versions are computed at release. Inputs `java-version`, `mysql-test-image`; secret `PUBLISH_TOKEN`. |
| `.github/workflows/java-library-publish.yml` | Reusable release for a java library, on a push to its release branch. Job `publish-package`: git-cliff with `cliff.toml` computes the version `V` from the commits since the last `vX.Y.Z` tag; never overwrites (a published `V` is skipped only when `v<V>` is on this commit, else the job fails); `RELEASE_VERSION=V` build and `gradle publish`; annotated tag `v<V>`; GitHub Release with git-cliff's notes and the Maven coordinates. Never prunes old versions. Caller grants `contents: write`, `packages: write`. Inputs `artifact-id`, `checks-ref`, `release-branch`, `java-version`, `mysql-test-image`, `git-cliff-version`, `git-cliff-sha256`; secrets `PUBLISH_TOKEN`, optional `LIBRARY_WEBHOOK_URI`. |
| `cliff.toml` | git-cliff config for library releases: `tag_pattern` `^v[0-9]+\.[0-9]+\.[0-9]+$`; breaking → major (also from 0.x), `feat` → minor, anything else → patch; notes list each commit's `Refs:`. |
| `.github/workflows/mutation-nightly.yml` | Reusable nightly mutation run (PIT) for a java repo. Job `mutation`: runs PIT on the classes changed on `develop` since the last successful run (state in artifact `mutation-state`, 90 days; a full run when it is missing or not an ancestor; a night with no `src/main` or `src/test` change records the SHA and skips PIT; a changed test named after no existing production class is dropped from the targets; `scripts/mutation-survivors.py pit-result` fails the run when PIT cannot run (tests fail under PIT without mutation, a Gradle or PIT error, or no report when mutations were found) and counts "No mutations found" as zero survivors, except on a full run; callers MUST NOT set PIT thresholds), then files one issue per production class through `scripts/mutation-survivors.py`, titled `Mutation survivors: <fully.qualified.Class>`, label `mutation-survivor`, created with the run's `GITHUB_TOKEN` and never duplicating an open one. Report uploaded as `pitest-report`. Job `alert` (after `mutation`, always, `scripts/mutation-alert.sh`, tested by `scripts/test-mutation-alert.sh` with a stub `gh`): a failed or cancelled run opens one issue `mutation-nightly red: <repo>` (labels `bug`, `area:test-infra`, `priority:P1`) with the failing step, the run link and the last 30 log lines, or comments on it when it is already open; the next green run closes it. Inputs `java-version`, `checks-ref`, `force-failure` (fails the run before PIT, to prove the alert; callers pass it from a `workflow_dispatch` input); secret `PUBLISH_TOKEN` (pass `secrets: inherit`); caller grants `contents: read`, `issues: write`, `actions: read`, `packages: read`. |
| `.github/workflows/mutation-pr.yml` | Reusable PR-time mutation check (PIT) for a java repo (pth-context platform-ops decision 0132). Called as its own job (`mutation`, listed in the caller's `ci-ok` `needs`), so java services and libraries share it and adopting it moves no build-workflow pin. Job `pit` (skipped on Dependabot runs): runs `scripts/mutation-pr.sh <base>` (base = the PR's or merge group's base SHA; any other event fails): maps the PR's changed files to classes with the nightly's mapping, runs `./gradlew pitest -PpitestTargetClasses=<classes>`, and fails only when PIT cannot run (`mutation-survivors.py pit-result`: tests fail under PIT without mutation, a PIT or Gradle error, no report when mutations were found). Surviving mutants never fail it (a notice counts them; the nightly files them). No class to mutate: PIT skipped, pass. Tested by `scripts/test-mutation-pr.sh` (throwaway git repo, stub `gradlew` replaying real PIT logs). Report uploaded as `pitest-report-pr` (7 days). Inputs `java-version`, `checks-ref`; secret `PUBLISH_TOKEN`; caller grants `contents: read`, `packages: read`. The build MUST NOT set PIT thresholds. |
| `.github/workflows/terraform-ci.yml` | Reusable static terraform check. Job `validate`, by `mode`: `modules` (fmt, init without backend, validate, tflint errors) or `live` (terragrunt hclfmt per file). No credentials. Inputs `mode`, `terraform-version`, `terragrunt-version`, `terragrunt-sha256`, `tflint-version`. |
| `.github/workflows/paired-tests.yml` | Reusable check of a PR's pasted platform-tests evidence. Job `check` (call it as a job named `paired-tests`, so callers see `paired-tests / check`): reads the PR from the API, resolves the expected commit with the handbook's `tools/pt-ref` (release mode on a base of `master` or `main`) and runs `scripts/paired-tests-check.sh`. A head with no issue number, a non-prod base and no line (Dependabot) passes without a token. No job-level `if`. Also runs on `merge_group`: the PR number comes from the queue ref through `scripts/queue-pr-number.sh`. A caller using the merge queue adds `on: merge_group` and the concurrency key `${{ github.event.pull_request.number || github.event.merge_group.head_ref }}`. Inputs `checks-ref`, `handbook-ref` (default `master`), `app-id` (pass `vars.PTH_CI_APP_ID`); secret optional `PTH_CI_APP_KEY`; caller grants `contents: read`, `pull-requests: read`. The App token covers only `engineering-handbook`, `platform-tests` and the calling repo. A caller whose `ci.yml` also runs on `push` MUST name the push run's ci-ok differently (`name: ${{ github.event_name == 'push' && 'ci-ok (push)' \|\| 'ci-ok' }}`), or a push run's ci-ok can satisfy the PR's required `ci-ok` without this check. |
| `.github/workflows/paired-tests-rerun.yml` | Reusable re-run of only the `paired-tests` job in a PR's latest `ci.yml` run (on a PR body edit, or when the paired platform-tests PR moves), through `scripts/rerun-paired-tests.sh`, so `ci-ok` keeps the real build result. Inputs `checks-ref`, `repo` (owner/repo), `pr`, `app-id`; secret optional `PTH_CI_APP_KEY`. Without the App, the caller grants `actions: write`, `pull-requests: read`. The `edited`-trigger caller SHOULD set `concurrency: {group: paired-tests-rerun-<pr number>, cancel-in-progress: true}`. |
| `scripts/queue-pr-number.sh` | `<head_ref>`: prints the PR number from the merge_group head ref `refs/heads/gh-readonly-queue/<branch>/pr-<n>-<40 hex>` (the full ref GitHub sends; the short form without `refs/heads/` is accepted too); any other ref exits 1 with `not a merge-queue ref: <ref>`. |
| `scripts/paired-tests-check.sh` | `<repo> <pr>`: paired PRs need a `platform-tests:` line equal to the paired head; unpaired PRs pass without one, and a line must be in platform-tests `master`'s history. Exit 0 pass, 1 mismatch, 2 resolver or API error. `--gate` only writes `needed=true\|false`. |
| `scripts/parse-pt-line.sh` | Prints the sha of a PR body's `platform-tests: <sha>` line (stdin; CRLF and indent tolerated), or nothing. Exit 3 on more than one distinct sha. |
| `scripts/rerun-paired-tests.sh` | `<owner/repo> <pr>`: waits (60 s polls, 60 min) for the head's newest `ci.yml` run to complete, then re-runs its job named `paired-tests…`. No run: exit 0. No such job: exit 1. |
| `scripts/test-paired-tests.sh` | Tests for the scripts (incl. `queue-pr-number.sh`) with stub `gh` and `pt-ref` and recorded JSON in `scripts/fixtures/paired-tests/`. |
| `.github/workflows/pact-publish.yml` | Reusable publish of a consumer repo's contract (Pact) files to GHCR. Job `publish`: downloads the `pacts` artifact (a notice and no push when absent), then on the default branch pushes its `*.json` to `ghcr.io/plantechhubdev/<package>` tagged `default` and `sha-<7>`. Inputs `package`, `checks-ref`, `artifact`, `tag` (push only that `pr-<n>` tag, on any branch); caller grants `actions: read` (to list the run's artifacts), `contents: read`, `packages: write`. |
| `scripts/pact/` | `default-branch.sh` (the default branch, from the event or the API), `oci-push.sh [--tag <tag>] <package> <dir> <sha>` (push `default` and `sha-<7>` on the default branch only; with `--tag pr-<n>`, only that tag on any branch; `default` and `sha-` tags are refused), `oci-pull.sh [--pr-tags <days>] <out-dir> <package>...` (pull `:default`, and with `--pr-tags` also each `pr-<n>` tag created under `<days>` days ago, laid out as source folders `<out-dir>/default/<package>` and `<out-dir>/pr-<n>/<package>`; without it the layout stays `<out-dir>/<package>`; unpublished or ungranted packages are skipped with a notice, other errors fail), `install-oras.sh` (pinned `oras`, sha256-checked), `digest.sh <pact.json>` (`<sha256>  <description>` per interaction, over providerStates, request and response), `gate.sh <provider> <new-pact> <base-pact> <results.json>` (the consumer gate), `results.sh <provider> <pacts-root> <reports-dir> <sha>` (provider results JSON on stdout, see below), `gate-providers.sh <gate-dir> <repo> <pacts-dir> <provider>...` (finds the pulled files per provider and runs `gate.sh`), `base-ref.sh` (PR or merge-group base branch), `show-summary.sh <report-dir> <pacts-dir> <provider>` (print workflow-command lines from `<report-dir>/*.txt`; fail when a consumer's fetched pacts for the provider outnumber the verified ones). |
| `scripts/test-pact.sh` | Tests for the pact scripts with stub `oras` and `gh` in `scripts/fixtures/pact/`. |
| `.github/workflows/ci.yml` | This repo's own CI: `checks` (the local `checks.yml`, so a PR here tests its own head), `lint` (actionlint, shellcheck, `scripts/test-*.sh`) and `ci-ok`. |

### Consumer contracts (Pact)

A consumer repo publishes the contract files its tests write; a provider repo verifies them in its own build. Both go through GHCR packages, so no repo reads another's source. Nothing changes for a repo that sets none of this.

- **Consumer.** `java-service-publish.yml` uploads `build/pacts/*.json` as artifact `pacts` (nothing when the build wrote none). The repo's `publish.yml` then calls `pact-publish.yml` with `package: <name>`. On the default branch the files are pushed to `ghcr.io/plantechhubdev/<name>` tagged `default` and `sha-<7>`; other branches print a notice.
- **Provider.** `java-service-ci.yml` input `pact-fetch-consumers` (space-separated package names). Before the build it installs `oras`, logs in with `GITHUB_TOKEN` and pulls each package's `default` tag into `$RUNNER_TEMP/pacts/<package>`, then sets `PACT_FOLDER=$RUNNER_TEMP/pacts` for the build. A package that is unpublished or has no grant is skipped with a notice (GHCR answers both with `denied`); any other error fails the job.
- **Consumer gate.** `java-service-ci.yml` input `pact-gate-providers` (space-separated provider names) uploads `build/pacts/*.json` as artifact `pacts` and, on `pull_request` and `merge_group` runs, checks each `build/pacts/<repo>-<provider>.json` against the provider's `pact-results-<provider>:default` (a `pact-results.json`) and this repo's `pacts-<repo>:default` (the default-branch pact). Every interaction that is new or changed relative to the default-branch pact must be listed as `passed` in the results, else the job fails with "<provider>'s default branch has not verified this call yet". Skipped with a notice when the base is not the default branch, the provider has no results yet, or the build wrote no pact for that provider; unchanged interactions without a passing result only warn. Repos that leave the input empty are unaffected.
- **Provider summary.** With `pact-fetch-consumers`, the step "Show contract verification summary" (`scripts/pact/show-summary.sh build/reports/pact "$RUNNER_TEMP/pacts" <service>`) prints every line of `build/reports/pact/*.txt` that starts with `::notice::`, `::warning::` or `::error::`, so they become annotations (Gradle hides test stdout). It then counts, per source folder and consumer, the pact files fetched for this service (any depth under `$RUNNER_TEMP/pacts`, `.provider.name` equal to the `service` input, which the pacts' provider name MUST match: if pacts were fetched but none name this service the step fails listing the names found, and a fetched package with none for this service only warns; consumers whose name ends `.pending` ignored, non-pact JSON skipped with a notice); when a consumer has k pacts in a source folder it fails the job unless `build/reports/pact/summary.txt` reports at least k verified for that consumer and folder, where the source folder is the first directory under the pacts dir when it is `default` or `pr-<n>` (else the flat layout, where the line's folder is not compared) and a line's `under <folder>` matches by its last path component, so `$RUNNER_TEMP/pacts/default` matches `default` (a missing or unusable consumer name cannot be covered); it runs unless the job was cancelled or the fetch step did not succeed, so the provider check cannot go green while verifying nothing. A provider that opts in MUST write those lines; the contract is one line per consumer and source folder, `::notice::verified <n> active pacts from <consumer> under <folder>` (the `<n>` are summed), in `summary.txt`, and pending-failure warnings (`::warning::...`) in `pending-warnings.txt`. With nothing fetched (nothing published or granted yet) the step prints a notice and passes.
- **Provider results.** `results.sh` turns pact-jvm JSON verification reports (`pact.verification.reports=console,json` and `pact.verification.reportDir=<dir>`) into `pact-results.json`: `{"provider","sha","interactions":[{"consumer","source","description","digest","status"}]}` with `status` `passed` or `failed`. `<pacts-root>` has one folder per source (`default`, `pr-<n>`, as `oci-pull.sh --pr-tags` lays them out; other folder names are skipped with a warning) and the provider runs one verification per source folder, writing reports to `<reports-dir>/<source>/` (pact-jvm merges everything one run verifies into a single `<provider>.json` in its reportDir, so a provider uses one reportDir per source, `<reports>/<source>/`); `results.sh` reads `<reports-dir>/<source>/*.json`. An interaction is `passed` only when its report entry (matched by consumer and description) has `verification.result` `OK`; one missing from the report is `failed` with a `::warning::`. Failures never fail the script. Push the file from a directory holding only `pact-results.json` to package `pact-results-<provider>` (`oci-push.sh`, default and `sha-<7>` tags).
- **Two grants** on each GHCR package (package settings, "Manage Actions access"): the consumer repo with **Write** (to push), and every provider repo with **Read** (to pull). The caller's `pacts` job also needs `actions: read` (to find the artifact) and `packages: write` for the publish job and `packages: read` for the `java-service-ci.yml` job.
- **Opt in.** Consumer: add the `pacts` job above to `publish.yml`. Provider: add `pact-fetch-consumers: pacts-consumer-a pacts-consumer-b` to the `with:` of the `java-service-ci.yml` call. Consumer gate: add `pact-gate-providers: provider-b provider-c` to the same call; the consumer's package MUST be named `pacts-<repo name>` for the gate to find its base pact. `install-oras.sh` supports linux amd64 only (the GitHub-hosted `ubuntu-latest` runners). Pin both to a tag that has these inputs (v2.3.0 or later; the provider's contract guard, `show-summary.sh`, needs v2.5.0 or later).

The commit standard itself (types, `Refs:`, `BREAKING CHANGE:`, exemptions) is documented in the engineering handbook, `workflow.md`, "Commits".

**Public here, private in `scripts`.** This repo is public, because GitHub only applies org defaults from a public `.github` repo, and because private repos can only call reusable workflows from a public repo (or with extra org settings). Only files that are safe for anyone to read belong here. Anything else tied to our environment (other deploy scripts, hostnames, anything that needs credentials) lives in the private `scripts` repo or in the repo it belongs to. The trunk release and simulation scripts (`pth-sim.sh`, `deployed-sha.sh`, `release-is-tip.sh`, `queue-run-green.sh`, `release-image.sh`, `ecr-retag.sh`, `ecs-deploy.sh`, `post-deploy-checks.sh`, `deploy-comment.sh`, `open-deploy-pr.sh` (kept, unused, for the later immutable-tags work) and the scripts they call) live here because reusable workflows run scripts from `checks-ref`, a ref of this repo, so they name no part of our environment: cluster, service, log group, alarm, profile, repo and path values come from caller inputs (passed from variables) or from the `pth-test` runner's environment, and tests and fixtures use placeholders (`example-service`, `other-service`, `region-a`, `registry.example.test`).

## Hygiene rules for this public repo

- Never commit secrets, account IDs, ARNs, cloud hostnames or company hostnames. Values a workflow needs come from org secrets or variables at run time.
- Never use `pull_request_target`. Workflows here run untrusted PR code with a read-only token only.
- Pin every third-party action by its full 40-character commit SHA, with the tag in a comment (`uses: owner/action@<sha> # vX.Y.Z`). Pin container images to an exact tag.
- Pass untrusted values (branch names, PR titles, commit messages) to `run:` steps through `env:`, never by `${{ }}` inside the script.
- Grant the least permissions: `contents: read` unless a job needs more.
- Fork PRs need a maintainer's approval before their workflows run.

## Using it from a repo

In the repo's `ci.yml`, pin a tag and pass the same tag as `checks-ref`, so CI runs the same `check-commit-msg.sh` as the hook:

```yaml
jobs:
  checks:
    uses: PlantechHubDev/.github/.github/workflows/checks.yml@v1.0.0
    with:
      checks-ref: v1.0.0
```

The build workflows are called the same way, as a job next to `checks`, with `permissions:` and `secrets:` given explicitly (never `secrets: inherit`). Each file's header shows its call. None of them has a job named `ci-ok`: the caller's own `ci-ok` job `needs:` them, and a publish run can never satisfy the required check. `pth-mysql-test` is pulled with the job's `GITHUB_TOKEN`, so its package settings must give each calling repo Read.

In the repo's `.pre-commit-config.yaml`:

```yaml
default_install_hook_types: [pre-commit, prepare-commit-msg, commit-msg]
repos:
  - repo: https://github.com/PlantechHubDev/.github
    rev: v1.0.0
    hooks:
      - id: add-issue-ref
      - id: check-commit-msg
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
        stages: [pre-commit]
```

Install once per clone (every worktree of the clone inherits the hooks): `brew install pre-commit`, then `pre-commit install` in the clone. Hooks are advisory (`--no-verify` and web edits skip them); CI is the gate.

## Trunk repos (merge queue)

A trunk repo merges through a GitHub merge queue into `master` instead of `develop` first. The queue builds the exact commit it will merge, simulates prod on it and, after the merge, a release workflow tags that same image `:master` and forces a new deployment of the prod service, only when the queue run and the release's own checks are all green. The `ci.yml` below runs on `pull_request` and `merge_group` only; it MUST NOT run on `push`, so a push run can never produce a `ci-ok` that satisfies the PR's required check (`scripts/test-workflow-names.sh` checks this example and every workflow here).

`ci.yml`: `checks`, `test` and `paired-tests` always; `image` and `pth-sim` only in the queue, with `pth-sim` taking `image`'s `digest`. `ci-ok` covers all of them: `allowed-skips: test, image, pth-sim` lets a `pull_request` run pass without `image` and `pth-sim` (and a Dependabot PR without `test`, which java-service-ci skips for Dependabot), and its first step fails a `merge_group` run unless `image` and `pth-sim` both passed.

```yaml
# ci.yml
name: ci

on:
  pull_request:
    branches: [master]
  merge_group:
    types: [checks_requested]

permissions:
  contents: read

concurrency:
  group: ci-${{ github.event.pull_request.number || github.event.merge_group.head_ref }}
  cancel-in-progress: true

jobs:
  checks:
    uses: PlantechHubDev/.github/.github/workflows/checks.yml@v2.4.0
    with:
      checks-ref: v2.4.0

  test:
    uses: PlantechHubDev/.github/.github/workflows/java-service-ci.yml@v2.4.0
    permissions:
      contents: read
      checks: write
      packages: read
    with:
      service: example-service
      checks-ref: v2.4.0
    secrets:
      PUBLISH_TOKEN: ${{ secrets.PUBLISH_TOKEN }}

  paired-tests:
    uses: PlantechHubDev/.github/.github/workflows/paired-tests.yml@v2.4.0
    permissions:
      contents: read
      pull-requests: read
    with:
      checks-ref: v2.4.0
      app-id: ${{ vars.PTH_CI_APP_ID }}
    secrets:
      PTH_CI_APP_KEY: ${{ secrets.PTH_CI_APP_KEY }}

  image:
    if: github.event_name == 'merge_group'
    uses: PlantechHubDev/.github/.github/workflows/java-service-image.yml@v2.4.0
    permissions:
      contents: read
      id-token: write
      packages: read
    with:
      service-name: example-service
      role-to-assume: ${{ vars.ECR_PUSH_ROLE_ARN }}
      checks-ref: v2.4.0
    secrets:
      packages-read-token: ${{ secrets.PUBLISH_TOKEN }}

  pth-sim:
    if: github.event_name == 'merge_group'
    needs: image
    uses: PlantechHubDev/.github/.github/workflows/pth-sim.yml@v2.4.0
    permissions:
      contents: read
    with:
      service-name: example-service
      digest: ${{ needs.image.outputs.digest }}
      checks-ref: v2.4.0

  ci-ok:
    if: always()
    needs: [checks, test, paired-tests, image, pth-sim]
    runs-on: ubuntu-latest
    steps:
      # allowed-skips would also pass a queue run whose image or pth-sim skipped: in the queue
      # both MUST have run and passed.
      - name: In the queue, image and pth-sim passed
        env:
          IMAGE_RESULT: ${{ needs.image.result }}
          SIM_RESULT: ${{ needs.pth-sim.result }}
        run: |
          if [ "$GITHUB_EVENT_NAME" = merge_group ] && { [ "$IMAGE_RESULT" != success ] || [ "$SIM_RESULT" != success ]; }; then
            echo "::error::in the merge queue, image and pth-sim must pass (image: $IMAGE_RESULT, pth-sim: $SIM_RESULT)"
            exit 1
          fi
      - name: All required jobs passed
        uses: re-actors/alls-green@b5b5b37504aa4183270bd3d855c52a67f212be35 # v1.3.0
        with:
          jobs: ${{ toJSON(needs) }}
          allowed-skips: test, image, pth-sim
```

`release.yml`: on the push the queue's fast-forward makes to `master`, `github.sha` is the commit the queue built and simulated, so nothing is rebuilt. The enqueue is the go for both the merge and the deploy: the release retags `:master` and forces the deployment only when the queue run for that commit was green and the prod service deploys `:master`.

```yaml
# release.yml
name: release

on:
  push:
    branches: [master]

permissions:
  contents: read

jobs:
  release:
    uses: PlantechHubDev/.github/.github/workflows/java-service-release.yml@v2.6.0
    permissions:
      contents: read
      id-token: write
      actions: read
      pull-requests: write
    with:
      service-name: example-service
      role-to-assume: ${{ vars.DEPLOY_ROLE_ARN }}
      checks-ref: v2.6.0
      ci-workflow: ci.yml
      ecs-cluster: ${{ vars.ECS_CLUSTER }}
      ecs-service: ${{ vars.ECS_SERVICE }}
      log-group: ${{ vars.LOG_GROUP }}
      alarm-prefix: ${{ vars.ALARM_PREFIX }}
```

What a caller needs, by name only: org or repo variables `vars.ECR_PUSH_ROLE_ARN` and `vars.PTH_CI_APP_ID` (for `ci.yml`), `vars.DEPLOY_ROLE_ARN` (the deploy role, trusted only for `master` and this workflow at a tag), `vars.ECS_CLUSTER`, `vars.ECS_SERVICE`, `vars.LOG_GROUP` and `vars.ALARM_PREFIX` (the environment's names are kept in variables, never in this public repo; they are per service, so they are repo variables), and secrets `secrets.PTH_CI_APP_KEY` and `secrets.PUBLISH_TOKEN` (for `ci.yml`). The release job runs in the GitHub environment `prod`, which the caller repo must have. The prod service's task definition MUST deploy `<registry>/<service>:master`, or the release fails before the retag; its service container MUST log with the `awslogs` driver to `LOG_GROUP` with an `awslogs-stream-prefix`, or the post-deploy checks fail (exit 2). The `pth-test` self-hosted runner, the `trunk` ruleset (required check `ci-ok`, merge queue) and the merge queue settings are configured outside this repo: see the engineering handbook and the org rulesets.

The `pth-test` runner's environment MUST set these (names only; the values live on the runner, never in this repo). `pth-sim.sh` has no defaults for them and exits 64 naming every one that is missing:

| Variable | What it names |
|---|---|
| `PTH_ECS_CLUSTER` | the prod ECS cluster |
| `PTH_ECS_SERVICE_TEMPLATE` | the prod ECS service name, with `{short}` standing for the service name without `-service` |
| `PTH_AWS_PROFILE` | the read-only AWS SSO profile |
| `PTH_STACK_LIB` | the handbook's `pth-stack` library |
| `PT_REF` | the handbook's `pt-ref` |
| `PTH_PT_DIR` | the platform-tests clone (its `.worktrees/` holds the run's worktree) |
| `PTH_DEMO_DIR` | the demo checkout platform-tests builds the portal from |
| `PTH_DOCKER_HOST` | the Docker daemon socket, as a `DOCKER_HOST` value |

The runner runs queue jobs only while it is online: a runner that is offline or asleep stalls the queue until it comes back or the job times out.

## Releasing and adopting a new tag

1. Change this repo by PR into `master`. Its own CI runs the changed `checks.yml` and scripts at the PR head.
2. After the merge, tag the merge commit with an annotated semver tag: `git tag -a vX.Y.Z -m "vX.Y.Z" <merge-sha>` and push it. A breaking change to inputs, job names or the commit standard is a major version.
3. Adopt the tag one repo at a time, starting with platform-tests, by a PR in that repo that changes all three pins together: the `uses: ...checks.yml@vX.Y.Z` line, `checks-ref: vX.Y.Z`, and `rev: vX.Y.Z` in `.pre-commit-config.yaml`. Then run `pre-commit install` again in each clone if the hook types changed.
4. Never move or delete a published tag; callers pin it.

From v2.4.0, `checks-ref` MUST equal the `uses` tag in every caller, because `secret-scan` (like `commit-lint`) now runs scripts read at `checks-ref` (`scripts/event-range.sh`), and `pth-sim` refuses a `checks-ref` that is not a release tag.
