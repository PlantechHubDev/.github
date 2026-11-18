#!/usr/bin/env bash
# Tests pth-sim.sh with fakes from scripts/fixtures/pth-sim/bin: aws, gh and npm first on PATH,
# pt-ref through PT_REF, and the pth-stack library through PTH_STACK_LIB. DEV is a temp dir
# holding a local platform-tests clone (git only, no network), so nothing touches AWS, GitHub,
# docker or the real pth-test stack.
# Usage: bash scripts/test-pth-sim.sh   (exit 0 when every case passes)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$HERE/fixtures/pth-sim/bin
export PATH="$BIN:$PATH"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export AWS_LOG=$T/aws.log GH_LOG=$T/gh.log PT_LOG=$T/pt.log NPM_LOG=$T/npm.log STACK_LOG=$T/stack.log
export PT_REF=$BIN/pt-ref PTH_STACK_LIB=$BIN/pth-stack GITHUB_STEP_SUMMARY=$T/summary.md
unset FAKE_SSO FAKE_SSO_FROM FAKE_URI FAKE_TAGS FAKE_GH_EXIT FAKE_DEPLOYED_2 FAKE_TEST_EXIT FAKE_TEST_SLEEP FAKE_UP_EXIT FAKE_CI_EXIT FAKE_STACK_BUSY FAKE_STACK_REFUSE PT_EXIT PT_ERR
unset PTH_STACK PTH_STACK_LOCK

# A local platform-tests "origin" and its clone at $DEV/platform-tests; pt-ref names its commit.
export DEV=$T/dev
G() { git -c commit.gpgsign=false -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.invalid "$@"; }
G init -q "$T/pt-origin" && G -C "$T/pt-origin" commit -q --allow-empty -m one
PTSHA=$(git -C "$T/pt-origin" rev-parse HEAD)
mkdir -p "$DEV" && G clone -q "$T/pt-origin" "$DEV/platform-tests"

Q=sha256:$(printf 'a%.0s' $(seq 64))           # queue image digest
D=sha256:$(printf 'd%.0s' $(seq 64))           # digest prod runs
DEPLOYED=$(printf '1%.0s' $(seq 40))           # its commit (fake gh)
QSHA=$(printf '2%.0s' $(seq 40))               # queue commit
export FAKE_QUEUE=$Q FAKE_DEPLOYED=$D FAKE_COMMIT=$DEPLOYED PT_OUT="$PTSHA master"
SVC=orchestration-service
status=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; status=1; }
# run <name> <want-exit> <args...>: pth-sim.sh with fresh logs; stdout+stderr in $out.
run() {
  local name=$1 want=$2; shift 2
  : > "$AWS_LOG"; : > "$GH_LOG"; : > "$PT_LOG"; : > "$NPM_LOG"; : > "$STACK_LOG"; : > "$GITHUB_STEP_SUMMARY"
  out=$(bash "$HERE/pth-sim.sh" "$@" 2>&1); code=$?
  if [ "$code" = "$want" ]; then pass "$name"; else fail "$name" "exit $code want $want; output: $out"; fi
}
has()    { if [[ $out == *"$2"* ]]; then pass "$1"; else fail "$1" "output lacks '$2': $out"; fi; }
logs()   { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1" "$(basename "$2") lacks '$3': $(cat "$2")"; fi; }
nologs() { if grep -qF -- "$3" "$2"; then fail "$1" "$(basename "$2") has '$3'"; else pass "$1"; fi; }
empty()  { if [ -s "$2" ]; then fail "$1" "$(basename "$2") not empty: $(cat "$2")"; else pass "$1"; fi; }
last()   { local l; l=$(printf '%s\n' "$out" | tail -n 1); if [ "$l" = "$2" ]; then pass "$1"; else fail "$1" "last line '$l' want '$2'"; fi; }

# --- usage (64)
run "usage: empty digest exits 64" 64 $SVC "" "$QSHA"
has "usage: empty digest says why" "digest must be sha256:"
last "usage: RESULT 64 is the last line" "RESULT 64"
run "usage: short digest exits 64" 64 $SVC "sha256:abc" "$QSHA"
run "usage: missing queue sha exits 64" 64 $SVC "$Q"
run "usage: bad queue sha exits 64" 64 $SVC "$Q" "1234567"
run "usage: bad service name exits 64" 64 "orchestration" "$Q" "$QSHA"
empty "usage: no aws call" "$AWS_LOG"
DEV="" run "usage: DEV unset exits 64" 64 $SVC "$Q" "$QSHA"
has "usage: DEV unset says so" "DEV is not set"

# --- happy path
run "pass: exits 0" 0 $SVC "$Q" "$QSHA"
last "pass: RESULT 0 is the last line" "RESULT 0"
logs "pass: running digest read from ECS" "$AWS_LOG" "ecs list-tasks --cluster prod-pth-cluster --service-name prod-$SVC-svc --desired-status RUNNING"
logs "pass: queue digest checked in the service's repo" "$AWS_LOG" "ecr describe-images --repository-name $SVC --image-ids imageDigest=$Q"
logs "pass: deployed commit from the sha- tag" "$GH_LOG" "commits/1111111"
logs "pass: pt-ref in release mode deployed..queue" "$PT_LOG" "$SVC --release $DEPLOYED..$QSHA"
logs "pass: env:up with the queue image by digest (short name)" "$NPM_LOG" "run env:up -- --portal --prod-fleet --image orchestration=registry.example/$SVC@$Q"
logs "pass: tests allow a non-master image" "$NPM_LOG" "test -- --allow-non-master"
logs "pass: npm runs in the verify worktree" "$NPM_LOG" "$DEV/platform-tests/.worktrees/verify-1 | ci"
if [ "$(git -C "$DEV/platform-tests/.worktrees/verify-1" rev-parse HEAD 2>/dev/null)" = "$PTSHA" ]; then pass "pass: worktree detached at the pt-ref commit"; else fail "pass: worktree detached at the pt-ref commit" "HEAD is not $PTSHA"; fi
logs "pass: phases recorded" "$STACK_LOG" "phase tests"
logs "pass: stack released with 0" "$STACK_LOG" "released 0"
logs "pass: summary names the platform-tests commit" "$GITHUB_STEP_SUMMARY" "$PTSHA"
logs "pass: summary names the queue commit" "$GITHUB_STEP_SUMMARY" "$QSHA"
logs "pass: summary names the deployed commit" "$GITHUB_STEP_SUMMARY" "$DEPLOYED"
logs "pass: summary names the service" "$GITHUB_STEP_SUMMARY" "$SVC"
logs "pass: summary gives the result" "$GITHUB_STEP_SUMMARY" "pass"

# --- test failure (1), cleanup ran
FAKE_TEST_EXIT=1 run "test failure exits 1" 1 $SVC "$Q" "$QSHA"
last "test failure: RESULT 1 is the last line" "RESULT 1"
logs "test failure: env:down ran" "$NPM_LOG" "run env:down"
logs "test failure: stack released with 1" "$STACK_LOG" "released 1"
logs "test failure: summary says failed" "$GITHUB_STEP_SUMMARY" "fail"
FAKE_UP_EXIT=7 run "env:up failure exits 1" 1 $SVC "$Q" "$QSHA"
nologs "env:up failure: no tests run" "$NPM_LOG" "| test"
logs "env:up failure: env:down ran" "$NPM_LOG" "run env:down"

# --- two paired changes (3)
PT_EXIT=2 PT_ERR="pt-ref: 2 paired platform-tests PRs in $DEPLOYED..$QSHA: platform-tests#11 (via $SVC#5), platform-tests#12 (via $SVC#6); split the release" \
  run "two paired PRs exit 3" 3 $SVC "$Q" "$QSHA"
has "two paired: names the first PR" "platform-tests#11"
has "two paired: names the second PR" "platform-tests#12"
last "two paired: RESULT 3 is the last line" "RESULT 3"
empty "two paired: no npm call" "$NPM_LOG"
empty "two paired: no stack taken" "$STACK_LOG"
PT_EXIT=2 PT_ERR="pt-ref: GraphQL error" run "other pt-ref error exits 2" 2 $SVC "$Q" "$QSHA"
empty "pt-ref error: no npm call (no fallback to master)" "$NPM_LOG"
last "pt-ref error: RESULT 2 is the last line" "RESULT 2"
PT_EXIT=0 PT_OUT="" run "pt-ref prints nothing: exit 2" 2 $SVC "$Q" "$QSHA"

# --- expired SSO (4): before npm and the lock
FAKE_SSO=expired run "SSO expired exits 4" 4 $SVC "$Q" "$QSHA"
has "SSO expired: plain message" "SSO session expired: run aws sso login"
last "SSO expired: RESULT 4 is the last line" "RESULT 4"
empty "SSO expired: no npm call" "$NPM_LOG"
empty "SSO expired: no stack taken" "$STACK_LOG"
empty "SSO expired: no pt-ref call" "$PT_LOG"
FAKE_SSO=missing run "SSO missing credentials exits 4" 4 $SVC "$Q" "$QSHA"
has "SSO missing: plain message" "SSO session expired: run aws sso login"
empty "SSO missing: no npm call" "$NPM_LOG"

# --- SSO expires while waiting for the stack: re-checked after the lease, exit 4, lease released
FAKE_SSO_FROM=sts run "SSO expired after the lease exits 4" 4 $SVC "$Q" "$QSHA"
logs "SSO after lease: identity re-checked" "$AWS_LOG" "sts get-caller-identity"
nologs "SSO after lease: env:up never ran" "$NPM_LOG" "env:up"
logs "SSO after lease: stack released" "$STACK_LOG" "released"
has "SSO after lease: plain message" "SSO session expired: run aws sso login"
last "SSO after lease: RESULT 4 is the last line" "RESULT 4"
FAKE_SSO_FROM=sts-missing run "no credentials after the lease exits 4" 4 $SVC "$Q" "$QSHA"

# --- wrong or stale digests (2)
FAKE_QUEUE=sha256:$(printf 'f%.0s' $(seq 64)) run "queue digest not in this service's ECR exits 2" 2 $SVC "$Q" "$QSHA"
has "queue digest unknown: names the service" "not an image in $SVC"
last "queue digest unknown: RESULT 2 is the last line" "RESULT 2"
empty "queue digest unknown: no npm call" "$NPM_LOG"
FAKE_DEPLOYED_2=sha256:$(printf 'e%.0s' $(seq 64)) run "prod mid-deploy (two digests) exits 2" 2 $SVC "$Q" "$QSHA"
has "mid-deploy: says so" "different digests"
FAKE_TAGS="master" run "deployed digest without sha- tag exits 2" 2 $SVC "$Q" "$QSHA"
empty "no sha- tag: no npm call" "$NPM_LOG"

# --- busy pool: says it waits, never silent
FAKE_STACK_BUSY=1 FAKE_STACK_WAIT=1 run "busy pool: gives up with exit 2 when no stack comes" 2 $SVC "$Q" "$QSHA"
has "busy pool: says it is waiting" "waiting for a pth-test stack"
nologs "busy pool: env:up never ran" "$NPM_LOG" "env:up"
FAKE_STACK_REFUSE=1 run "per-session refusal exits 2" 2 $SVC "$Q" "$QSHA"
empty "refusal: no npm call" "$NPM_LOG"
last "refusal: RESULT 2 is the last line" "RESULT 2"

# --- registry URI shape
FAKE_URI="registry.example/orchestration-service extra" run "malformed repository URI exits 2" 2 $SVC "$Q" "$QSHA"
empty "bad URI: no npm call" "$NPM_LOG"
FAKE_URI="" run "empty repository URI exits 2" 2 $SVC "$Q" "$QSHA"

# --- setup failures after the lease (2), lease released
FAKE_CI_EXIT=1 run "npm ci failure exits 2" 2 $SVC "$Q" "$QSHA"
nologs "npm ci failure: env:up never ran" "$NPM_LOG" "env:up"
logs "npm ci failure: stack released" "$STACK_LOG" "released"
last "npm ci failure: RESULT 2 is the last line" "RESULT 2"
PT_OUT="$(printf '9%.0s' $(seq 40)) master" run "worktree checkout failure exits 2" 2 $SVC "$Q" "$QSHA"
nologs "checkout failure: npm never ran" "$NPM_LOG" "| ci"
last "checkout failure: RESULT 2 is the last line" "RESULT 2"

# --- a job cancel or timeout (SIGTERM) releases the lease through the library's traps
: > "$NPM_LOG"; : > "$STACK_LOG"; : > "$GITHUB_STEP_SUMMARY"
FAKE_TEST_SLEEP=30 bash "$HERE/pth-sim.sh" $SVC "$Q" "$QSHA" > "$T/term.out" 2>&1 & spid=$!
for _ in $(seq 100); do grep -qF '| test' "$NPM_LOG" && break; sleep 0.1; done
kill -TERM "$spid"; wait "$spid"; code=$?; out=$(cat "$T/term.out")
if [ "$code" != 0 ]; then pass "SIGTERM: exits non-zero"; else fail "SIGTERM: exits non-zero" "exit 0; output: $out"; fi
logs "SIGTERM: stack released" "$STACK_LOG" "released"
logs "SIGTERM: env:down ran" "$NPM_LOG" "run env:down"
last "SIGTERM: RESULT is the last line" "RESULT 143"
exit $status
