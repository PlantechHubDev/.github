#!/usr/bin/env bash
# commit-lint-gate.sh: decide whether commit-lint runs, and over which range.
# Reads env: EVENT HEAD_REF HEAD_REPO REPO AUTHOR PR_BASE PR_HEAD MG_BASE MG_HEAD
# On merge_group it also reads the commit authors of MG_BASE..MG_HEAD from the repository
# checkout in the working directory (checks.yml checks it out with full history first).
# Writes "lint=true|false" and "range=<base>..<head>" to $GITHUB_OUTPUT.
# Exit 1 when a pull request's branch name breaks the branch-name rule.
set -u
lint=false
long_lived=false
range=""
case "${HEAD_REF:-}" in
  develop | master | main | test | demo) long_lived=true ;;
esac
if [ "${EVENT:-}" = merge_group ]; then
  # The queue's branch is named gh-readonly-queue/...: it was checked at PR time.
  # Lint the commits the queue adds on top of the base branch.
  for v in MG_BASE MG_HEAD; do
    if [ -z "${!v:-}" ]; then
      echo "::error::merge_group event without $v: cannot work out the queue's range"
      exit 1
    fi
  done
  lint=true
  range="$MG_BASE..$MG_HEAD"
  # The PR gate skipped Dependabot PRs; skip them here too. Only when every non-merge commit in
  # the range (read from the checkout) is authored by dependabot[bot]; an empty or unreadable
  # range lints.
  if authors=$(git log --no-merges --format=%an "$range" 2>/dev/null) && [ -n "$authors" ] \
    && ! printf '%s\n' "$authors" | grep -qvxF 'dependabot[bot]'; then
    echo "Merge queue: every commit in $range is by dependabot[bot], a Dependabot update the PR gate skipped too: skipping."
    lint=false
    range=""
  fi
elif [ "${EVENT:-}" != pull_request ]; then
  echo "Event '${EVENT:-}': commit-lint runs on pull requests and the merge queue only."
elif [ "$long_lived" = true ] && [ "$HEAD_REPO" = "$REPO" ]; then
  # Only this repo's own long-lived branches skip; a fork's
  # develop/master is linted like any other head.
  echo "Head '$HEAD_REF' is a long-lived branch of $REPO: skipping."
elif [ "${AUTHOR:-}" = 'dependabot[bot]' ]; then
  echo "Dependabot PR: skipping."
elif printf '%s\n' "$HEAD_REF" | grep -Eq '^(feat|fix|chore|docs|hotfix)/[0-9]+-[a-z0-9]+(-[a-z0-9]+)*$' \
  || printf '%s\n' "$HEAD_REF" | grep -Eq '^revert-[0-9]+-'; then
  lint=true
  range="$PR_BASE..$PR_HEAD"
else
  echo "::error::Branch '$HEAD_REF' (from $HEAD_REPO) must match ^(feat|fix|chore|docs|hotfix)/[0-9]+-[a-z0-9]+(-[a-z0-9]+)*\$ (or GitHub's revert-<n>-...)."
  exit 1
fi
echo "lint=$lint" >>"$GITHUB_OUTPUT"
echo "range=$range" >>"$GITHUB_OUTPUT"
