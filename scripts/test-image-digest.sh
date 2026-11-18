#!/usr/bin/env bash
# Tests image-digest.sh (digest from build-push metadata or describe-images JSON) and
# ecr-existing-digest.sh (does sha-<7> already exist in ECR?) with fixture JSON and a fake aws.
# Usage: bash scripts/test-image-digest.sh   (exit 0 when every case passes)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FX=$HERE/fixtures/image
DIGEST=sha256:$(printf 'ab%.0s' $(seq 32))
status=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; status=1; }

# check <name> <want-exit> <want-stdout> <cmd...>: stdout compared exactly, stderr kept apart.
check() {
  local name=$1 want=$2 wantout=$3; shift 3
  local out code
  out=$("$@" 2>/dev/null); code=$?
  if [ "$code" != "$want" ]; then fail "$name" "exit $code want $want"
  elif [ "$out" != "$wantout" ]; then fail "$name" "stdout '$out' want '$wantout'"
  else pass "$name"; fi
}
# shellcheck disable=SC2329  # invoked through check
digest() { bash "$HERE/image-digest.sh" "$@" < "$FX/$FILE"; }
# shellcheck disable=SC2329  # invoked through check
existing() { PATH="$FX/bin:$PATH" FAKE_AWS_MODE=$MODE bash "$HERE/ecr-existing-digest.sh" other-service sha-1234567; }

FILE=metadata-ok.json;      check "metadata: valid prints digest" 0 "$DIGEST" digest
FILE=metadata-missing.json; check "metadata: missing digest exits 1" 1 "" digest
FILE=metadata-short.json;   check "metadata: short hex exits 1" 1 "" digest
FILE=describe-found.json;   check "existing: describe-images JSON prints digest" 0 "$DIGEST" digest --existing
FILE=describe-empty.json;   check "existing: empty imageDetails exits 1" 1 "" digest --existing
FILE=metadata-ok.json;      check "existing: metadata JSON is not describe-images" 1 "" digest --existing

MODE=found;   check "ecr: image exists prints digest" 0 "$DIGEST" existing
MODE=missing; check "ecr: ImageNotFoundException prints nothing, exit 0" 0 "" existing
MODE=denied;  check "ecr: any other aws error exits 1" 1 "" existing

# --- usage (64)
FILE=metadata-ok.json; check "usage: unknown option exits 64" 64 "" digest --bogus
check "usage: ecr-existing-digest with no args exits 64" 64 "" bash "$HERE/ecr-existing-digest.sh"
check "usage: ecr-existing-digest with one arg exits 64" 64 "" bash "$HERE/ecr-existing-digest.sh" other-service
check "usage: ecr-existing-digest with an empty tag exits 64" 64 "" bash "$HERE/ecr-existing-digest.sh" other-service ""
exit $status
