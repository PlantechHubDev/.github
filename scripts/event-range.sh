#!/usr/bin/env bash
# event-range.sh: work out the git range the secret scan covers for the triggering event.
# Reads env: EVENT PR_BASE PR_HEAD BEFORE AFTER SHA DEFAULT_BRANCH MG_BASE MG_HEAD
# Writes "range=<git rev-list args, or empty>" to $GITHUB_OUTPUT.
# Exit 1 on an event other than push, pull_request or merge_group.
set -u
zero=$(printf '%040d' 0)   # the all-zeros SHA GitHub sends for a created or deleted branch
case "${EVENT:-}" in
  pull_request)
    range="$PR_BASE..$PR_HEAD" ;;
  merge_group)
    # The queue's temporary branch: everything it adds on top of the base branch.
    range="$MG_BASE..$MG_HEAD" ;;
  push)
    head=${AFTER:-${SHA:-}}
    if [ "$head" = "$zero" ]; then
      echo "Branch deleted: nothing to scan."
      range=""
    elif [ -n "${BEFORE:-}" ] && [ "$BEFORE" != "$zero" ] \
      && git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
      range="$BEFORE..$head"
    else
      # New branch, or a force-push whose old tip is gone: scan the
      # commits that are not on the default branch.
      range="$head --not refs/remotes/origin/$DEFAULT_BRANCH"
    fi ;;
  *)
    echo "::error::checks.yml supports push, pull_request and merge_group events, not '${EVENT:-}'"
    exit 1 ;;
esac
echo "Range: ${range:-<none>}"
echo "range=$range" >>"$GITHUB_OUTPUT"
