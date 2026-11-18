#!/usr/bin/env bash
# Tests deployed-sha.sh (image digest -> sha-<7> ECR tag -> full commit) with the fake aws and
# gh in scripts/fixtures/pth-sim/bin first on PATH, so nothing touches AWS or GitHub.
# Usage: bash scripts/test-deployed-sha.sh   (exit 0 when every case passes)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH="$HERE/fixtures/pth-sim/bin:$PATH"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export AWS_LOG=$T/aws.log GH_LOG=$T/gh.log
D=sha256:$(printf 'd%.0s' $(seq 64))
SHA=$(printf '1%.0s' $(seq 40))
export FAKE_DEPLOYED=$D FAKE_COMMIT=$SHA
unset FAKE_SSO FAKE_TAGS FAKE_GH_EXIT FAKE_QUEUE FAKE_DEPLOYED_2
status=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; status=1; }
# run <name> <want-exit> <args...>: deployed-sha.sh with fresh logs; stdout in $out, stderr in $err.
run() {
  local name=$1 want=$2; shift 2
  : > "$AWS_LOG"; : > "$GH_LOG"
  out=$(bash "$HERE/deployed-sha.sh" "$@" 2>"$T/err"); code=$?; err=$(cat "$T/err")
  if [ "$code" = "$want" ]; then pass "$name"; else fail "$name" "exit $code want $want; stdout '$out' stderr '$err'"; fi
}
is()     { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got '$2' want '$3'"; fi; }
has()    { if [[ $2 == *"$3"* ]]; then pass "$1"; else fail "$1" "lacks '$3': $2"; fi; }
logs()   { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1" "$(basename "$2") lacks '$3': $(cat "$2")"; fi; }
empty()  { if [ -s "$2" ]; then fail "$1" "$(basename "$2") not empty: $(cat "$2")"; else pass "$1"; fi; }

run "ok: digest resolves to the full commit" 0 orchestration-service "$D"
is   "ok: prints the 40-hex sha" "$out" "$SHA"
logs "ok: describe-images by digest in the service's repo" "$AWS_LOG" "ecr describe-images --repository-name orchestration-service --image-ids imageDigest=$D"
logs "ok: commit looked up by the sha- tag" "$GH_LOG" "api repos/PlantechHubDev/orchestration-service/commits/1111111"

run "usage: no args" 64
run "usage: one arg" 64 orchestration-service
run "usage: empty digest" 64 orchestration-service ""
has "usage: names the digest rule" "$err" "digest must be sha256:"
run "usage: short digest" 64 orchestration-service "sha256:abc"
run "usage: bad service name" 64 "Orch/x" "$D"
empty "usage: no aws call" "$AWS_LOG"

FAKE_TAGS="master latest" run "no sha- tag exits 2" 2 orchestration-service "$D"
has "no sha- tag: says so" "$err" "no sha-<7> tag"
empty "no sha- tag: no gh call" "$GH_LOG"
FAKE_TAGS="sha-1111111 sha-2222222" run "two sha- tags exit 2" 2 orchestration-service "$D"
has "two sha- tags: ambiguous" "$err" "ambiguous"
run "unknown digest exits 2" 2 orchestration-service "sha256:$(printf 'e%.0s' $(seq 64))"
has "unknown digest: names the repository" "$err" "orchestration-service"

FAKE_SSO=expired run "expired SSO exits 4" 4 orchestration-service "$D"
has "expired SSO: plain message" "$err" "SSO session expired: run aws sso login"
FAKE_SSO=missing run "missing credentials exits 4" 4 orchestration-service "$D"

FAKE_GH_EXIT=1 FAKE_GH_ERR="gh: No commit found for SHA: 1111111 (HTTP 422)" run "gh lookup failure exits 2" 2 orchestration-service "$D"
has "gh failure: passes gh's reason on" "$err" "No commit found"
FAKE_COMMIT=1111111 run "gh returns a non-40-hex sha: exit 2" 2 orchestration-service "$D"
exit $status
