#!/usr/bin/env bash
# Tests ecr-retag.sh (copy the manifest of <service>:<from-tag> to <to-tag>, no rebuild) with the
# fake aws in scripts/fixtures/deploy-pr/bin first on PATH, so nothing touches AWS.
# Usage: bash scripts/test-ecr-retag.sh   (exit 0 when every case passes)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH="$HERE/fixtures/deploy-pr/bin:$PATH"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export AWS_LOG=$T/aws.log
A=sha256:$(printf 'a%.0s' $(seq 64))
export FAKE_SRC_DIGEST=$A
unset FAKE_SRC_MISSING FAKE_PUT_ERR FAKE_AWS_DENIED
SVC=orchestration-service
status=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; status=1; }
# run <name> <want-exit> <args...>: ecr-retag.sh with a fresh log; stdout in $out, stderr in $err.
run() {
  local name=$1 want=$2; shift 2
  : > "$AWS_LOG"
  out=$(bash "$HERE/ecr-retag.sh" "$@" 2>"$T/err"); code=$?; err=$(cat "$T/err")
  if [ "$code" = "$want" ]; then pass "$name"; else fail "$name" "exit $code want $want; stdout '$out' stderr '$err'"; fi
}
is()     { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got '$2' want '$3'"; fi; }
has()    { if [[ $2 == *"$3"* ]]; then pass "$1"; else fail "$1" "lacks '$3': $2"; fi; }
logs()   { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1" "$(basename "$2") lacks '$3': $(cat "$2")"; fi; }
nologs() { if grep -qF -- "$3" "$2"; then fail "$1" "$(basename "$2") has '$3'"; else pass "$1"; fi; }
empty()  { if [ -s "$2" ]; then fail "$1" "$(basename "$2") not empty: $(cat "$2")"; else pass "$1"; fi; }

run "ok: retag exits 0" 0 $SVC sha-abc1234 master
is   "ok: prints the digest" "$out" "$A"
logs "ok: reads the source manifest by tag" "$AWS_LOG" "ecr batch-get-image --repository-name $SVC --image-ids imageTag=sha-abc1234"
logs "ok: accepts an OCI index (multi-arch) without conversion" "$AWS_LOG" "application/vnd.oci.image.index.v1+json"
logs "ok: puts the same manifest under the new tag" "$AWS_LOG" "ecr put-image --repository-name $SVC --image-tag master --image-manifest {\"schemaVersion\":2"
logs "ok: passes the manifest media type" "$AWS_LOG" "--image-manifest-media-type application/vnd.oci.image.index.v1+json"
logs "ok: pins the digest on put-image" "$AWS_LOG" "--image-digest $A"
is   "ok: only the two ECR calls (no build, no push)" "$(cut -d' ' -f1-2 "$AWS_LOG" | tr '\n' ',')" "ecr batch-get-image,ecr put-image,"

FAKE_SRC_MISSING=1 run "missing source image exits 2" 2 $SVC sha-abc1234 master
has "missing source: says never rebuilt" "$err" "sha-abc1234 not found"
nologs "missing source: no put-image" "$AWS_LOG" "put-image"
is "missing source: prints nothing" "$out" ""

FAKE_PUT_ERR=ImageAlreadyExistsException run "tag already on this digest exits 0 (re-run)" 0 $SVC sha-abc1234 master
is "already there: prints the digest" "$out" "$A"
FAKE_PUT_ERR=ImageTagAlreadyExistsException run "immutable tag exits 1" 1 $SVC sha-abc1234 master
has "immutable tag: passes aws's reason on" "$err" "ImageTagAlreadyExistsException"
FAKE_AWS_DENIED=1 run "access denied exits 1" 1 $SVC sha-abc1234 master
has "access denied: passes aws's reason on" "$err" "AccessDeniedException"

run "usage: no args" 64
run "usage: two args" 64 $SVC sha-abc1234
run "usage: bad service" 64 "Orch/x" sha-abc1234 master
run "usage: bad tag" 64 $SVC "sha abc" master
empty "usage: no aws call" "$AWS_LOG"
exit $status
