# Reviewing changes to .github

This public repo holds the org-wide defaults and shared checks for every repo behind ScenariosX, scenario-based financial planning software for financial advisors: the reusable checks, build, publish and Terraform validation workflows, the commit hooks, the library release config, and the default issue and PR templates. Every repo calls these by tag, so a wrong change here weakens the gate on every repo at once, breaks every build that adopts the tag, or leaks something into a public repo.

## Failure modes

- **Check silently skips or passes**: a reusable workflow change that makes a check skip, pass or report green for every calling repo without doing its work: an `if:` condition that matches more than intended, a skip for a branch or actor that a fork or new branch can also claim, `continue-on-error`, a script that exits 0 on failure, or a job the caller's aggregate check no longer waits on. Look for every changed condition and ask which callers now skip, and check that a misconfigured caller still fails loudly.
- **Moved tag breaks callers**: a change to inputs, secrets, job names, outputs or the commit standard that breaks callers pinned to the next tag, or a release that moves or reuses an existing tag. Look for removed or renamed inputs and jobs, newly required inputs or secrets, and anything that is not marked as a major version when it should be.
- **Widened secret or token scope**: a workflow that grants more permissions than its job needs, passes secrets that are not used, accepts `secrets: inherit`, uses `pull_request_target`, or runs untrusted pull request code with a write token or with secrets. Look at every `permissions:` and `secrets:` block and every trigger.
- **Untrusted input in a script**: a branch name, PR title, commit message or other value from the event interpolated with `${{ }}` straight into a `run:` script instead of passed through `env:`, which allows command injection from a branch name or title.
- **Unpinned or moving dependency**: a third-party action not pinned by its full commit SHA, a container image without an exact tag, or a downloaded tool without a checksum, so the code that runs in every repo can change without a change here.
- **Wrong version computed**: a change to the release config or publish workflow that computes the wrong next version, overwrites a published version, skips the tag or release, or prunes old versions that consumers still resolve. Look for changed commit-type rules, tag patterns and overwrite guards.
- **Private detail in a public repo**: an account ID, ARN, hostname, service or environment name, email or credential written into a workflow, hook, template or doc. Environment-specific values come from org secrets or variables at run time.

## Reporting

- Every finding cites the file and line it is about, as `path:line`, with the evidence for it.
- Report at most 3 nits; drop the rest.
- Start the summary with the number of findings. When there is nothing to fix, say so plainly in the first line.
