#!/usr/bin/env bash
# rerun-paired-tests.sh: re-run only the paired-tests job of a PR's latest ci.yml run, so the
# check re-reads the PR body and the paired platform-tests head. Re-running the one job keeps
# the run's other results, so ci-ok still sees the real build result.
#
# Usage: rerun-paired-tests.sh <owner/repo> <pr-number>
#
# Steps: read the PR's head sha; find the newest ci.yml run for it (pull_request event); wait
# until that run is completed, polling every $PAIRED_TESTS_POLL_INTERVAL seconds (default 60)
# for up to $PAIRED_TESTS_POLL_TIMEOUT seconds (default 3600); then POST a re-run of the job
# whose name starts with "paired-tests" (the caller's job, e.g. "paired-tests / check").
#
# Exit: 0 re-run requested, or no ci.yml run for the head yet (the next push runs the check
#       anyway); 1 the run has no paired-tests job (a wiring bug), the wait timed out, or an
#       API call failed; 64 usage.
# Needs gh and jq; gh authenticates through GH_TOKEN (actions: write, pull-requests: read).
set -uo pipefail

usage() { echo "usage: rerun-paired-tests.sh <owner/repo> <pr-number>" >&2; exit 64; }
die() { echo "::error::rerun-paired-tests: $*"; exit 1; }

[ $# -eq 2 ] || usage
repo=$1 pr=$2
[[ $repo =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]] || usage
[[ $pr =~ ^[0-9]+$ ]] || usage
interval=${PAIRED_TESTS_POLL_INTERVAL:-60}
timeout=${PAIRED_TESTS_POLL_TIMEOUT:-3600}
[[ $interval =~ ^[0-9]+$ ]] && [[ $timeout =~ ^[0-9]+$ ]] \
  || die "PAIRED_TESTS_POLL_INTERVAL and PAIRED_TESTS_POLL_TIMEOUT must be whole seconds"

head_sha=$(gh api "repos/$repo/pulls/$pr" --jq .head.sha) || die "cannot read $repo#$pr"
[[ $head_sha =~ ^[0-9a-f]{40}$ ]] || die "$repo#$pr has no head sha ('$head_sha')"

deadline=$(( $(date +%s) + timeout ))
while :; do
  run=$(gh api "repos/$repo/actions/workflows/ci.yml/runs?head_sha=$head_sha&event=pull_request" \
    --jq '.workflow_runs | max_by(.created_at) // empty | "\(.id) \(.status)"') \
    || die "cannot list ci.yml runs for $repo@$head_sha"
  if [ -z "$run" ]; then
    echo "::notice::rerun-paired-tests: no ci.yml run for $repo#$pr head $head_sha yet; nothing to re-run (the next push runs the check)"
    exit 0
  fi
  read -r run_id run_status <<<"$run"
  [ "$run_status" = completed ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    die "timed out after ${timeout}s waiting for ci.yml run $run_id ($run_status) of $repo#$pr to complete"
  fi
  echo "ci.yml run $run_id is $run_status; checking again in ${interval}s"
  sleep "$interval"
done

job_id=$(gh api "repos/$repo/actions/runs/$run_id/jobs?per_page=100" \
  --jq '[.jobs[] | select(.name | startswith("paired-tests"))] | first // empty | .id') \
  || die "cannot list the jobs of ci.yml run $run_id"
[ -n "$job_id" ] \
  || die "ci.yml run $run_id of $repo#$pr has no paired-tests job; its ci.yml must call paired-tests.yml as a job named paired-tests"

gh api -X POST "repos/$repo/actions/jobs/$job_id/rerun" >/dev/null \
  || die "cannot re-run job $job_id of ci.yml run $run_id"
echo "::notice::rerun-paired-tests: re-running job $job_id (paired-tests) of ci.yml run $run_id for $repo#$pr"
