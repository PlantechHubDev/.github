#!/usr/bin/env bash
# Prints the branch a pull request or merge-group run targets: $PR_BASE_REF (github.base_ref, pull_request)
# or $MERGE_GROUP_BASE_REF (merge_group, github.event.merge_group.base_ref) with "refs/heads/"
# stripped. Prints nothing when neither is set.
set -euo pipefail
ref=${PR_BASE_REF:-}
[ -n "$ref" ] || ref=${MERGE_GROUP_BASE_REF:-}
printf '%s\n' "${ref#refs/heads/}"
