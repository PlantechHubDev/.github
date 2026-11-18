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
# A real repo so push can resolve BEFORE: c1 <- c2 on master, c3 on top.
G=$T/repo; mkdir "$G"
git -C "$G" init -q -b master
git -C "$G" -c user.name=t -c user.email=t@t commit -q --allow-empty -m c1
C1=$(git -C "$G" rev-parse HEAD)
git -C "$G" -c user.name=t -c user.email=t@t commit -q --allow-empty -m c2
C2=$(git -C "$G" rev-parse HEAD)
git -C "$G" update-ref refs/remotes/origin/master "$C1"
# shellcheck disable=SC2329  # invoked through run
rng_in_repo() { (cd "$G" && rng "$@"); }
run "range: push before..after"     0 rng_in_repo EVENT=push BEFORE="$C1" AFTER="$C2" SHA="$C2" DEFAULT_BRANCH=master
outputs "range: push before..after range" "range=$C1..$C2"
run "range: push unknown old tip"   0 rng_in_repo EVENT=push BEFORE="$A" AFTER="$C2" SHA="$C2" DEFAULT_BRANCH=master
outputs "range: unknown old tip falls back" "range=$C2 --not refs/remotes/origin/master"
run "range: push deleted branch"    0 rng EVENT=push BEFORE="$A" AFTER="$ZERO" SHA="$B" DEFAULT_BRANCH=master
outputs "range: deleted branch empty range" "range="
run "range: push new branch"        0 rng EVENT=push BEFORE="$ZERO" AFTER="$B" SHA="$B" DEFAULT_BRANCH=master
outputs "range: new branch not-on-default" "range=$B --not refs/remotes/origin/master"
run "range: merge_group empty MG_BASE" 1 rng EVENT=merge_group MG_BASE= MG_HEAD="$B"
has "range: empty MG_BASE names it" "::error::"
has "range: empty MG_BASE message" "MG_BASE"
run "range: merge_group unset MG_HEAD" 1 rng EVENT=merge_group MG_BASE="$A"
has "range: unset MG_HEAD names it" "MG_HEAD"
run "range: workflow_dispatch"      1 rng EVENT=workflow_dispatch
has "range: dispatch message" "supports push, pull_request and merge_group"

# --- commit-lint-gate.sh
run "gate: merge_group"             0 gate EVENT=merge_group HEAD_REF="$QUEUE_REF" MG_BASE="$A" MG_HEAD="$B"
outputs "gate: merge_group lints" "lint=true"
outputs "gate: merge_group range" "range=$A..$B"
run "gate: merge_group ignores branch name" 0 gate EVENT=merge_group HEAD_REF=bad-name MG_BASE="$A" MG_HEAD="$B"
outputs "gate: bad-name still lints in queue" "lint=true"
run "gate: merge_group empty MG_HEAD" 1 gate EVENT=merge_group HEAD_REF="$QUEUE_REF" MG_BASE="$A" MG_HEAD=
has "gate: empty MG_HEAD error" "::error::"
has "gate: empty MG_HEAD names it" "MG_HEAD"
run "gate: merge_group unset MG_BASE" 1 gate EVENT=merge_group HEAD_REF="$QUEUE_REF" MG_HEAD="$B"
has "gate: unset MG_BASE names it" "MG_BASE"
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

# --- merge_group with Dependabot commits: a real repo, since the gate reads the queue's commits.
# The PR gate skipped a Dependabot PR, so the queue skips it too when every non-merge commit in
# MG_BASE..MG_HEAD is authored by dependabot[bot]; any other author (or no readable range) lints.
R=$T/mg-repo
MG() { git -C "$R" -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
as() { local who=$1; shift; MG -c user.name="$who" -c user.email="$who@example.invalid" "$@"; }
git init -q -b master "$R"
as dev commit -q --allow-empty -m "chore: base"
BASE=$(MG rev-parse HEAD)
MG checkout -q -b bump
as 'dependabot[bot]' commit -q --allow-empty -m "Bump a from 1 to 2"
as 'dependabot[bot]' commit -q --allow-empty -m "Bump b from 3 to 4"
MG checkout -q master
as 'github' merge -q --no-ff bump -m "Merge pull request #5 from o/dependabot/x"
DEPHEAD=$(MG rev-parse HEAD)
MG checkout -q -b mixed bump
as dev commit -q --allow-empty -m "fix: tweak"
MIXHEAD=$(MG rev-parse HEAD)
# shellcheck disable=SC2329  # invoked through run
gate_in() { (cd "$R" && gate "$@"); }
run "gate: merge_group all-Dependabot exits 0" 0 gate_in EVENT=merge_group HEAD_REF="$QUEUE_REF" MG_BASE="$BASE" MG_HEAD="$DEPHEAD"
outputs "gate: merge_group all-Dependabot lint=false" "lint=false"
has "gate: merge_group all-Dependabot says why" "Dependabot"
run "gate: merge_group Dependabot plus another author" 0 gate_in EVENT=merge_group HEAD_REF="$QUEUE_REF" MG_BASE="$BASE" MG_HEAD="$MIXHEAD"
outputs "gate: mixed authors lint=true" "lint=true"
outputs "gate: mixed authors range" "range=$BASE..$MIXHEAD"
run "gate: merge_group empty range still lints" 0 gate_in EVENT=merge_group HEAD_REF="$QUEUE_REF" MG_BASE="$BASE" MG_HEAD="$BASE"
outputs "gate: empty range lint=true" "lint=true"
run "gate: merge_group unreadable range lints" 0 gate_in EVENT=merge_group HEAD_REF="$QUEUE_REF" MG_BASE="$A" MG_HEAD="$B"
outputs "gate: unreadable range lint=true" "lint=true"

exit $status
