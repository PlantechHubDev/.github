#!/usr/bin/env bash
# Tests ecr-retag.sh (copy the manifest of <service>:<from-tag> to <to-tag>, no rebuild) and
# release-image.sh (retag sha-<7> as master only when prod does not pin :master) with the fake aws in scripts/fixtures/deploy-pr/bin first on PATH, so nothing touches AWS.
# Usage: bash scripts/test-ecr-retag.sh   (exit 0 when every case passes)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH="$HERE/fixtures/deploy-pr/bin:$PATH"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export AWS_LOG=$T/aws.log
A=sha256:$(printf 'a%.0s' $(seq 64))
export FAKE_SRC_DIGEST=$A
unset FAKE_SRC_MISSING FAKE_PUT_ERR FAKE_AWS_DENIED FAKE_TAG_DIGEST GITHUB_OUTPUT
SVC=example-service
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

# --- release-image.sh <service> <merge-sha> < pins: the digest to deploy, retagging only when no
# prod unit (any region) pins :master or fails to parse. Pins on stdin: "<path> <pin>" per unit,
# as `open-deploy-pr.sh --pins` prints them.
MERGE=abc1234$(printf '0%.0s' $(seq 33))
export GITHUB_OUTPUT=$T/output
EAST=live/region-a/prod/$SVC/terragrunt.hcl
WEST=live/region-b/prod/$SVC/terragrunt.hcl
# rel <name> <want-exit> <pins> <args...>
rel() {
  local name=$1 want=$2 pins=$3; shift 3
  : > "$AWS_LOG"; : > "$GITHUB_OUTPUT"
  out=$(printf '%s' "$pins" | bash "$HERE/release-image.sh" "$@" 2>"$T/err"); code=$?; err=$(cat "$T/err")
  if [ "$code" = "$want" ]; then pass "$name"; else fail "$name" "exit $code want $want; stdout '$out' stderr '$err'"; fi
}
hasnt() { if [[ $2 == *"$3"* ]]; then fail "$1" "has '$3': $2"; else pass "$1"; fi; }

FAKE_TAG_DIGEST=$A rel "east master pin: exits 0" 0 "$EAST tag:master"$'\n' $SVC "$MERGE"
nologs "east master pin: :master not moved (no put-image)" "$AWS_LOG" "put-image"
logs "east master pin: sha-<7> digest read read-only" "$AWS_LOG" "ecr describe-images --repository-name $SVC --image-ids imageTag=sha-abc1234"
has  "east master pin: warns" "$out" "::warning::"
has  "east master pin: warning names the unit" "$out" "$EAST"
is   "east master pin: digest is the last line" "$(printf '%s\n' "$out" | tail -n 1)" "$A"
logs "east master pin: digest in GITHUB_OUTPUT" "$GITHUB_OUTPUT" "digest=$A"
logs "east master pin: retagged=false in GITHUB_OUTPUT" "$GITHUB_OUTPUT" "retagged=false"
logs "east master pin: held-by names the unit in GITHUB_OUTPUT" "$GITHUB_OUTPUT" "held-by=$EAST"

FAKE_TAG_DIGEST=$A rel "DR master pin: exits 0" 0 "$EAST digest"$'\n'"$WEST tag:master"$'\n' $SVC "$MERGE"
nologs "DR master pin: :master not moved (no put-image)" "$AWS_LOG" "put-image"
has  "DR master pin: warning names the region-b unit" "$out" "::warning::"
has  "DR master pin: names $WEST" "$out" "$WEST"
hasnt "DR master pin: does not blame the digest-pinned unit" "$out" "$EAST"
logs "DR master pin: digest in GITHUB_OUTPUT" "$GITHUB_OUTPUT" "digest=$A"
logs "DR master pin: held-by names only the region-b unit" "$GITHUB_OUTPUT" "held-by=$WEST"

FAKE_TAG_DIGEST=$A rel "DR unparseable: exits 0" 0 "$EAST digest"$'\n'"$WEST unparseable"$'\n' $SVC "$MERGE"
nologs "DR unparseable: no retag (fails closed)" "$AWS_LOG" "put-image"
has  "DR unparseable: warning names the unit" "$out" "$WEST"
FAKE_TAG_DIGEST=$A rel "garbled pin line: exits 0" 0 "$EAST digest"$'\n'"$WEST"$'\n' $SVC "$MERGE"
nologs "garbled pin line: no retag" "$AWS_LOG" "put-image"
FAKE_TAG_DIGEST=$A rel "no pins at all: exits 0" 0 "" $SVC "$MERGE"
nologs "no pins at all: no retag (fails closed)" "$AWS_LOG" "put-image"
has  "no pins at all: warns" "$out" "::warning::"
logs "no pins at all: retagged=false" "$GITHUB_OUTPUT" "retagged=false"

rel "all digest pins: exits 0" 0 "$EAST digest"$'\n'"$WEST digest"$'\n' $SVC "$MERGE"
logs "all digest pins: retagged sha-<7> as master" "$AWS_LOG" "ecr put-image --repository-name $SVC --image-tag master"
logs "all digest pins: digest in GITHUB_OUTPUT" "$GITHUB_OUTPUT" "digest=$A"
logs "all digest pins: retagged=true in GITHUB_OUTPUT" "$GITHUB_OUTPUT" "retagged=true"
logs "all digest pins: held-by empty" "$GITHUB_OUTPUT" "held-by="
nologs "all digest pins: no retagged=false" "$GITHUB_OUTPUT" "retagged=false"
hasnt "all digest pins: no warning" "$out" "::warning::"
rel "other tag pin: exits 0" 0 "$EAST tag:latest"$'\n'"$WEST digest"$'\n' $SVC "$MERGE"
logs "other tag pin: retagged" "$AWS_LOG" "put-image"

rel "east master pin, sha-<7> missing: exits 2" 2 "$EAST tag:master"$'\n' $SVC "$MERGE"
has "east master pin, missing: says so" "$err" "sha-abc1234"
nologs "east master pin, missing: no digest output" "$GITHUB_OUTPUT" "digest="
FAKE_SRC_MISSING=1 rel "digest pins, sha-<7> missing: exits 2" 2 "$EAST digest"$'\n' $SVC "$MERGE"
nologs "digest pins, missing: no put-image" "$AWS_LOG" "put-image"
nologs "digest pins, missing: no digest output" "$GITHUB_OUTPUT" "digest="
nologs "digest pins, missing: no retagged output" "$GITHUB_OUTPUT" "retagged="
rel "usage: extra arg" 64 "" $SVC "$MERGE" digest
rel "usage: short sha" 64 "" $SVC abc1234
rel "usage: no args" 64 ""
exit $status
