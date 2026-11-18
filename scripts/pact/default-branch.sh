#!/usr/bin/env bash
# Prints the repository's default branch: $EVENT_DEFAULT_BRANCH when set and non-empty (the
# workflow passes github.event.repository.default_branch), else asks the API for
# $GITHUB_REPOSITORY (needs GH_TOKEN). Exits 1 if neither gives an answer.
set -euo pipefail
branch=${EVENT_DEFAULT_BRANCH:-}
if [ -z "$branch" ]; then
  branch=$(gh api "repos/${GITHUB_REPOSITORY:?}" --jq .default_branch)
fi
if [ -z "$branch" ]; then
  echo "::error::Cannot determine the default branch of ${GITHUB_REPOSITORY:-this repository}" >&2
  exit 1
fi
printf '%s\n' "$branch"
