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
| `.github/workflows/java-service-ci.yml` | Reusable build for a java service. Jobs: `test` (no committed `mavenLocal()`, then Gradle `clean build`; skipped on Dependabot runs) and `image-scan` (image built from `test`'s jar, Trivy CRITICAL/HIGH with `.trivyignore`). Inputs `service`, `java-version`, `mysql-test-image`; secret `PUBLISH_TOKEN`. |
| `.github/workflows/java-service-publish.yml` | Reusable publish for a java service. Job `build-push`: Gradle `clean build`, then a linux/amd64 + linux/arm64 image to ECR only, tagged `:<branch>` and `:sha-<7>`, through OIDC. Inputs `service`, `java-version`, `ecr-role-arn` (pass `vars.ECR_PUSH_ROLE_ARN`), `mysql-test-image`; secrets `PUBLISH_TOKEN`, optional `TEAMS_WEBHOOK_URI`. |
| `.github/workflows/java-library-ci.yml` | Reusable build for a java library. Job `test` (no committed `mavenLocal()`, then Gradle `clean build`; skipped on Dependabot runs). No `version-check` from v2.0.0: versions are computed at release. Inputs `java-version`, `mysql-test-image`; secret `PUBLISH_TOKEN`. |
| `.github/workflows/java-library-publish.yml` | Reusable release for a java library, on a push to its release branch. Job `publish-package`: git-cliff with `cliff.toml` computes the version `V` from the commits since the last `vX.Y.Z` tag; never overwrites (a published `V` is skipped only when `v<V>` is on this commit, else the job fails); `RELEASE_VERSION=V` build and `gradle publish`; annotated tag `v<V>`; GitHub Release with git-cliff's notes and the Maven coordinates. Never prunes old versions. Caller grants `contents: write`, `packages: write`. Inputs `artifact-id`, `checks-ref`, `release-branch`, `java-version`, `mysql-test-image`, `git-cliff-version`, `git-cliff-sha256`; secrets `PUBLISH_TOKEN`, optional `LIBRARY_WEBHOOK_URI`. |
| `cliff.toml` | git-cliff config for library releases: `tag_pattern` `^v[0-9]+\.[0-9]+\.[0-9]+$`; breaking → major (also from 0.x), `feat` → minor, anything else → patch; notes list each commit's `Refs:`. |
| `.github/workflows/terraform-ci.yml` | Reusable static terraform check. Job `validate`, by `mode`: `modules` (fmt, init without backend, validate, tflint errors) or `live` (terragrunt hclfmt per file). No credentials. Inputs `mode`, `terraform-version`, `terragrunt-version`, `terragrunt-sha256`, `tflint-version`. |
| `.github/workflows/paired-tests.yml` | Reusable check of a PR's pasted platform-tests evidence. Job `check` (call it as a job named `paired-tests`, so callers see `paired-tests / check`): reads the PR from the API, resolves the expected commit with the handbook's `tools/pt-ref` (release mode on a base of `master` or `main`) and runs `scripts/paired-tests-check.sh`. A head with no issue number, a non-prod base and no line (Dependabot) passes without a token. No job-level `if`. Inputs `checks-ref`, `handbook-ref` (default `master`), `app-id` (pass `vars.PTH_CI_APP_ID`); secret optional `PTH_CI_APP_KEY`; caller grants `contents: read`, `pull-requests: read`. The App token covers only `engineering-handbook`, `platform-tests` and the calling repo. A caller whose `ci.yml` also runs on `push` MUST name the push run's ci-ok differently (`name: ${{ github.event_name == 'push' && 'ci-ok (push)' \|\| 'ci-ok' }}`), or a push run's ci-ok can satisfy the PR's required `ci-ok` without this check. |
| `.github/workflows/paired-tests-rerun.yml` | Reusable re-run of only the `paired-tests` job in a PR's latest `ci.yml` run (on a PR body edit, or when the paired platform-tests PR moves), through `scripts/rerun-paired-tests.sh`, so `ci-ok` keeps the real build result. Inputs `checks-ref`, `repo` (owner/repo), `pr`, `app-id`; secret optional `PTH_CI_APP_KEY`. Without the App, the caller grants `actions: write`, `pull-requests: read`. The `edited`-trigger caller SHOULD set `concurrency: {group: paired-tests-rerun-<pr number>, cancel-in-progress: true}`. |
| `scripts/paired-tests-check.sh` | `<repo> <pr>`: paired PRs need a `platform-tests:` line equal to the paired head; unpaired PRs pass without one, and a line must be in platform-tests `master`'s history. Exit 0 pass, 1 mismatch, 2 resolver or API error. `--gate` only writes `needed=true\|false`. |
| `scripts/parse-pt-line.sh` | Prints the sha of a PR body's `platform-tests: <sha>` line (stdin; CRLF and indent tolerated), or nothing. Exit 3 on more than one distinct sha. |
| `scripts/rerun-paired-tests.sh` | `<owner/repo> <pr>`: waits (60 s polls, 60 min) for the head's newest `ci.yml` run to complete, then re-runs its job named `paired-tests…`. No run: exit 0. No such job: exit 1. |
| `scripts/test-paired-tests.sh` | Tests for the three scripts with stub `gh` and `pt-ref` and recorded JSON in `scripts/fixtures/paired-tests/`. |
| `.github/workflows/ci.yml` | This repo's own CI: `checks` (the local `checks.yml`, so a PR here tests its own head), `lint` (actionlint, shellcheck, `scripts/test-*.sh`) and `ci-ok`. |

The commit standard itself (types, `Refs:`, `BREAKING CHANGE:`, exemptions) is documented in the engineering handbook, `workflow.md`, "Commits".

**Public here, private in `scripts`.** This repo is public, because GitHub only applies org defaults from a public `.github` repo, and because private repos can only call reusable workflows from a public repo (or with extra org settings). Only generic, reusable files that are safe for anyone to read belong here. Anything tied to our environment (deploy and release scripts, account or service names, hostnames, anything that needs credentials) lives in the private `scripts` repo or in the repo it belongs to. This repo's own `scripts/` directory holds only the generic scripts the shared workflows run; its test fixtures use placeholder names (`example-service`), never real services or issues.

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

## Releasing and adopting a new tag

1. Change this repo by PR into `master`. Its own CI runs the changed `checks.yml` and scripts at the PR head.
2. After the merge, tag the merge commit with an annotated semver tag: `git tag -a vX.Y.Z -m "vX.Y.Z" <merge-sha>` and push it. A breaking change to inputs, job names or the commit standard is a major version.
3. Adopt the tag one repo at a time, starting with platform-tests, by a PR in that repo that changes all three pins together: the `uses: ...checks.yml@vX.Y.Z` line, `checks-ref: vX.Y.Z`, and `rev: vX.Y.Z` in `.pre-commit-config.yaml`. Then run `pre-commit install` again in each clone if the hook types changed.
4. Never move or delete a published tag; callers pin it.
