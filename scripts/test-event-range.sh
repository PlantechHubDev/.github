#!/usr/bin/env bash
# Tests event-range.sh and commit-lint-gate.sh (the shell behind checks.yml's range and
# lint-gate steps) for push, pull_request and merge_group events. Each case checks the
# exit code, text in the output, and the lines written to GITHUB_OUTPUT.
# Usage: bash scripts/test-event-range.sh   (exit 0 when every case passes)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GITHUB_OUTPUT=$T/out

x40() { printf "$1%.0s" $(seq 40); }
A=$(x40 a) B=$(x40 b) C=$(x40 c) D=$(x40 d)
ZERO=$(x40 0)
QUEUE_REF="gh-readonly-queue/master/pr-12-$B"
status=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; status=1; }

# run <name> <want-exit> <cmd...>: fresh GITHUB_OUTPUT; output (stdout+stderr) in $out.
run() {
  local name=$1 want=$2; shift 2
  : > "$GITHUB_OUTPUT"
  out=$("$@" 2>&1); code=$?
  if [ "$code" = "$want" ]; then pass "$name"; else fail "$name" "exit $code want $want; output: $out"; fi
}
has()     { if [[ $out == *"$2"* ]]; then pass "$1"; else fail "$1" "output lacks '$2': $out"; fi; }
outputs() { if grep -qxF -- "$2" "$GITHUB_OUTPUT"; then pass "$1"; else fail "$1" "GITHUB_OUTPUT lacks '$2': $(cat "$GITHUB_OUTPUT")"; fi; }

RANGE="$HERE/event-range.sh" GATE="$HERE/commit-lint-gate.sh"
# Each case sets only the variables its event provides, like the workflow's env block.
# shellcheck disable=SC2329  # invoked through run
rng() { env -i PATH="$PATH" GITHUB_OUTPUT="$GITHUB_OUTPUT" "$@" bash "$RANGE"; }
# shellcheck disable=SC2329  # invoked through run
gate() { env -i PATH="$PATH" GITHUB_OUTPUT="$GITHUB_OUTPUT" "$@" bash "$GATE"; }

# --- event-range.sh
run "range: merge_group"            0 rng EVENT=merge_group MG_BASE="$A" MG_HEAD="$B"
outputs "range: merge_group range" "range=$A..$B"
run "range: pull_request"           0 rng EVENT=pull_request PR_BASE="$A" PR_HEAD="$B"
outputs "range: pull_request range" "range=$A..$B"
run "range: push before..after"     0 rng EVENT=push BEFORE="$A" AFTER="$B" SHA="$B" DEFAULT_BRANCH=master
has "range: push unknown old tip falls back" "Range:"
run "range: push deleted branch"    0 rng EVENT=push BEFORE="$A" AFTER="$ZERO" SHA="$B" DEFAULT_BRANCH=master
outputs "range: deleted branch empty range" "range="
run "range: push new branch"        0 rng EVENT=push BEFORE="$ZERO" AFTER="$B" SHA="$B" DEFAULT_BRANCH=master
outputs "range: new branch not-on-default" "range=$B --not refs/remotes/origin/master"
run "range: workflow_dispatch"      1 rng EVENT=workflow_dispatch
has "range: dispatch message" "supports push, pull_request and merge_group"

# --- commit-lint-gate.sh
run "gate: merge_group"             0 gate EVENT=merge_group HEAD_REF="$QUEUE_REF" MG_BASE="$A" MG_HEAD="$B"
outputs "gate: merge_group lints" "lint=true"
outputs "gate: merge_group range" "range=$A..$B"
run "gate: pr good branch"          0 gate EVENT=pull_request HEAD_REF=feat/12-x HEAD_REPO=o/r REPO=o/r AUTHOR=me PR_BASE="$C" PR_HEAD="$D"
outputs "gate: pr lints" "lint=true"
outputs "gate: pr range" "range=$C..$D"
run "gate: pr bad branch"           1 gate EVENT=pull_request HEAD_REF=bad-name HEAD_REPO=o/r REPO=o/r AUTHOR=me PR_BASE="$C" PR_HEAD="$D"
has "gate: bad branch message" "must match"
run "gate: pr develop skips"        0 gate EVENT=pull_request HEAD_REF=develop HEAD_REPO=o/r REPO=o/r AUTHOR=me PR_BASE="$C" PR_HEAD="$D"
outputs "gate: develop lint=false" "lint=false"
run "gate: dependabot skips"        0 gate EVENT=pull_request HEAD_REF=dependabot/x HEAD_REPO=o/r REPO=o/r 'AUTHOR=dependabot[bot]'
outputs "gate: dependabot lint=false" "lint=false"
run "gate: push is a no-op"         0 gate EVENT=push
outputs "gate: push lint=false" "lint=false"

exit $status
