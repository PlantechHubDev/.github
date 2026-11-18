#!/usr/bin/env bash
# sim-run-url.sh <owner/repo> <commit> <ci-workflow-file>: print the html_url of the merge_group
# run of <ci-workflow-file> (e.g. ci.yml) whose head_sha is <commit>: the merge-queue run that
# built and simulated the image now being released. GitHub's merge queue fast-forwards master to
# the queue commit, so on push to master github.sha is that run's head_sha.
# Prints the text "simulation run: not found" (still exit 0) when no such run is found or the
# lookup fails, so the deploy PR still opens and says so.
# GitHub: gh, authenticated through GH_TOKEN (the release workflow: the caller's GITHUB_TOKEN with
# actions: read). Exit: 0 printed a URL or the not-found text; 64 usage.
set -uo pipefail
NOT_FOUND="simulation run: not found"
usage() { echo "sim-run-url: $1" >&2; echo "usage: sim-run-url.sh <owner/repo> <commit> <ci-workflow-file>" >&2; exit 64; }
[ $# -eq 3 ] || usage "expected 3 arguments, got $#"
repo=$1 sha=$2 wf=$3
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "bad repository '$repo'"
[[ $sha =~ ^[0-9a-f]{40}$ ]] || usage "commit must be 40 hex (got '$sha')"
[[ $wf =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]] || usage "workflow must be a file name such as ci.yml (got '$wf')"

if ! json=$(gh api "repos/$repo/actions/runs?event=merge_group&head_sha=$sha&per_page=100"); then
  echo "sim-run-url: cannot list merge_group runs of $repo for $sha" >&2
  echo "$NOT_FOUND"; exit 0
fi
# Runs come newest first; a workflow's path may carry an @ref suffix.
url=$(jq -r --arg p ".github/workflows/$wf" --arg s "$sha" \
  '[.workflow_runs[]? | select((.path == $p or (.path | startswith($p + "@"))) and .head_sha == $s)][0].html_url // empty' \
  <<<"$json" 2>/dev/null)
if [ -n "$url" ]; then echo "$url"; else echo "$NOT_FOUND"; fi
