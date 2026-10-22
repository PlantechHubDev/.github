# .github

Org-wide defaults and shared checks for every PlantechHubDev repo.

## What lives here

**Org defaults.** GitHub applies the files under `.github/` to any repo that has none of its own:

- `pull_request_template.md`: the PR description every repo uses.
- `ISSUE_TEMPLATE/`: Bug, Feature and Task, matching the org's issue types.

**Why one place.** Issues and PRs read the same way in every repo, so triage and review don't depend on which repo you are in, and a template changes once instead of per repo. Repos therefore don't keep their own issue templates; conventions are in the engineering handbook (`workflow.md`).

**Shared checks and hooks.**

| Path | What it is |
|---|---|
| `.github/workflows/checks.yml` | Reusable workflow every repo's `ci.yml` calls. Jobs: `secret-scan` (gitleaks over the push or PR range, `--redact`) and `commit-lint` (branch-name rule, then `hooks/check-commit-msg.sh` over the PR's commits). |
| `hooks/check-commit-msg.sh` | The commit standard: `<type>(<scope>)!: <description>` plus a `Refs:` trailer. Hook mode (`<msg-file>`) and CI mode (`--range <base>..<head>`). The same script runs locally and in CI, so the two can't drift. |
| `hooks/add-issue-ref.sh` | `prepare-commit-msg` hook: on `<type>/<issue>-<slug>` branches, appends `Refs: #<issue>` when the message has none. |
| `.pre-commit-hooks.yaml` | Publishes the two hooks (`add-issue-ref`, `check-commit-msg`) for the [pre-commit](https://pre-commit.com) framework. |
| `.pre-commit-config.yaml`, `.gitleaks.toml` | This repo's own hooks and gitleaks config. Every repo has the same two files. |
| `.github/workflows/ci.yml` | This repo's own CI: `checks` (the local `checks.yml`, so a PR here tests its own head), `lint` (actionlint, shellcheck) and `ci-ok`. |

The commit standard itself (types, `Refs:`, `BREAKING CHANGE:`, exemptions) is documented in the engineering handbook, `workflow.md`, "Commits".

**Public here, private in `scripts`.** This repo is public, because GitHub only applies org defaults from a public `.github` repo, and because private repos can only call reusable workflows from a public repo (or with extra org settings). Only generic, reusable files that are safe for anyone to read belong here. Anything tied to our environment (deploy and release scripts, account or service names, hostnames, anything that needs credentials) lives in the private `scripts` repo or in the repo it belongs to.

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
