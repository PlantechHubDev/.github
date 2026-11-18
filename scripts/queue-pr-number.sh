#!/usr/bin/env bash
# queue-pr-number.sh <head_ref>: print the PR number from a merge-queue head ref. GitHub's
# merge_group payload gives head_ref as the full ref, refs/heads/gh-readonly-queue/<base>/pr-<n>-<40
# hex sha>; the short form without refs/heads/ is accepted too. Exit 1 on any other ref.
# The pattern is the same as pth-sim.sh's check of MG_HEAD_REF.
set -u
ref=${1-}
branch=${ref#refs/heads/}
if [[ $branch =~ ^gh-readonly-queue/[A-Za-z0-9._/-]+/pr-([0-9]+)-[0-9a-f]{40}$ ]] && [[ $branch != *..* ]]; then
  echo "${BASH_REMATCH[1]}"
else
  echo "not a merge-queue ref: $ref" >&2
  exit 1
fi
