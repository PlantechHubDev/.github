#!/usr/bin/env bash
# queue-run-green.sh <owner/repo> <merge-sha> <ci-workflow-file>: the release's green gate. Exits
# 0 only when the merge queue's run for exactly this commit was green, so java-service-release.yml
# retags and deploys nothing otherwise.
#
# The run: the newest merge_group run of <ci-workflow-file> (e.g. ci.yml; its path may carry an
# @ref suffix) whose head_sha is <merge-sha> (the queue fast-forwards master to the commit it
# tested, so on push to master github.sha is that run's head_sha). Lookup as in sim-run-url.sh.
# Green means:
#   - the run is completed with conclusion success;
#   - no job (latest attempt, every page) concluded failure, cancelled, timed_out or action_required;
#   - the jobs ci-ok, image and pth-sim succeeded. A job of a called workflow appears as
#     "<caller job> / <job>", so each of these names is the group of jobs named exactly that or
#     starting with "<name> / ". A group passes when it has at least one success and nothing but
#     success or skipped (java-service-image.yml skips its build when sha-<7> already exists);
#     a missing or all-skipped group fails. Any other job skipped by its own if: is allowed.
#
# GitHub: gh, authenticated through GH_TOKEN (the caller's GITHUB_TOKEN with actions: read). No AWS.
# Prints the run's html_url on success. Exit: 0 green; 1 not green or the jobs could not be read
# (the reason in an ::error::); 2 no such run (or the run lookup failed); 64 usage.
set -uo pipefail
usage() { echo "queue-run-green: $1" >&2; echo "usage: queue-run-green.sh <owner/repo> <merge-sha> <ci-workflow-file>" >&2; exit 64; }
[ $# -eq 3 ] || usage "expected 3 arguments, got $#"
repo=$1 sha=$2 wf=$3
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "bad repository '$repo'"
[[ $sha =~ ^[0-9a-f]{40}$ ]] || usage "merge-sha must be 40 hex (got '$sha')"
[[ $wf =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]] || usage "workflow must be a file name such as ci.yml (got '$wf')"
REQUIRED=(ci-ok image pth-sim)
notgreen() { echo "::error::the merge queue run for ${sha:0:7} is not green: $*; nothing is retagged or deployed" >&2; exit 1; }

if ! json=$(gh api "repos/$repo/actions/runs?event=merge_group&head_sha=$sha&per_page=100"); then
  echo "::error::cannot list the merge_group runs of $repo for ${sha:0:7}; nothing is retagged or deployed" >&2; exit 2
fi
# Runs come newest first.
run=$(jq -c --arg p ".github/workflows/$wf" --arg s "$sha" \
  '[.workflow_runs[]? | select((.path == $p or (.path | startswith($p + "@"))) and .head_sha == $s)][0] // empty' \
  <<<"$json" 2>/dev/null)
if [ -z "$run" ]; then
  echo "::error::no merge_group run of $wf for ${sha:0:7} in $repo: the commit did not come through the merge queue; nothing is retagged or deployed" >&2; exit 2
fi
id=$(jq -r '.id' <<<"$run") url=$(jq -r '.html_url // ""' <<<"$run")
st=$(jq -r '.status // ""' <<<"$run") concl=$(jq -r '.conclusion // ""' <<<"$run")
[[ $id =~ ^[0-9]+$ ]] || notgreen "the run has no id"
[ "$st" = completed ] || notgreen "run $url is $st"
[ "$concl" = success ] || notgreen "run $url concluded ${concl:-nothing}"

# Every page: --paginate prints one {"jobs": [...]} object per page.
pages=$(gh api --paginate "repos/$repo/actions/runs/$id/jobs?filter=latest&per_page=100") || notgreen "cannot read the jobs of run $url"
jobs=$(jq -s -c '{jobs: [.[].jobs[]]}' <<<"$pages" 2>/dev/null) || notgreen "cannot read the jobs of run $url"
bad=$(jq -r '.jobs[] | select(.conclusion as $c | ["failure","cancelled","timed_out","action_required"] | index($c)) | "\(.name) (\(.conclusion))"' <<<"$jobs")
[ -z "$bad" ] || notgreen "jobs not passed: $(paste -sd, - <<<"$bad" | sed 's/,/, /g')"
for r in "${REQUIRED[@]}"; do
  group=$(jq -r --arg r "$r" '.jobs[] | select(.name == $r or (.name | startswith($r + " / "))) | "\(.conclusion // .status)\t\(.name)"' <<<"$jobs")
  [ -n "$group" ] || notgreen "no $r job in run $url"
  others=$(awk -F'\t' '$1 != "success" && $1 != "skipped" { print $2 " (" $1 ")" }' <<<"$group")
  [ -z "$others" ] || notgreen "$r not passed: $(paste -sd, - <<<"$others" | sed 's/,/, /g')"
  grep -q '^success' <<<"$group" || notgreen "$r not passed: $(awk -F'\t' '{ print $2 " (" $1 ")" }' <<<"$group" | paste -sd, - | sed 's/,/, /g')"
done
echo "queue-run-green: run $url for ${sha:0:7} is green (ci-ok, image and pth-sim passed)" >&2
echo "$url"
