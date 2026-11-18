#!/usr/bin/env bash
# queue-pr-number.sh <head_ref>: print the PR number from a merge-queue head ref,
# gh-readonly-queue/<branch>/pr-<n>-<40 hex sha>. Exit 1 on any other ref.
set -u
ref=${1-}
if [[ $ref =~ ^gh-readonly-queue/[^/]+/pr-([0-9]+)-[0-9a-f]{40}$ ]]; then
  echo "${BASH_REMATCH[1]}"
else
  echo "not a merge-queue ref: $ref" >&2
  exit 1
fi
