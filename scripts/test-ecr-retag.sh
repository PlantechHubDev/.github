#!/usr/bin/env bash
# Tests ecr-retag.sh (copy the manifest of <service>:<from-tag> to <to-tag>, no rebuild) and
# release-image.sh (guard: the running prod service deploys <service>:master, else exit 3; then retag sha-<7> as master) with fake aws (scripts/fixtures/deploy-pr/bin, and fixtures/ecs-deploy/bin for the guard) first on PATH, so nothing touches AWS.
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

# --- release-image.sh <service> <merge-sha> <cluster> <ecs-service>: the guard, then the retag.
# The guard reads what the running prod service deploys (describe-services -> its task
# definition): the container whose image is in the service's ECR repository MUST reference
# <anything>/<service>:master, because the release deploys by retagging :master and forcing a new
# deployment. A digest, another tag, or no container of the service's repository exits 3 naming
# the image, with no AWS write. Uses the ECS fake (fixtures/ecs-deploy/bin), which hands ECR
# calls to the deploy-pr fake.
MERGE=abc1234$(printf '0%.0s' $(seq 33))
export GITHUB_OUTPUT=$T/output FAKE_STATE=$T
CL=example-cluster SV=example-service-prod
unset FAKE_TD
# rel <name> <want-exit> <args...>
rel() {
  local name=$1 want=$2; shift 2
  : > "$AWS_LOG"; : > "$GITHUB_OUTPUT"
  out=$(PATH="$HERE/fixtures/ecs-deploy/bin:$PATH" bash "$HERE/release-image.sh" "$@" 2>"$T/err"); code=$?; err=$(cat "$T/err")
  if [ "$code" = "$want" ]; then pass "$name"; else fail "$name" "exit $code want $want; stdout '$out' stderr '$err'"; fi
}
hasnt() { if [[ $2 == *"$3"* ]]; then fail "$1" "has '$3': $2"; else pass "$1"; fi; }
writes() { if grep -qE 'put-image|update-service|register-task-definition' "$2"; then fail "$1" "AWS write: $(cat "$2")"; else pass "$1"; fi; }
SIDE='log-router registry.example.test/log-router:stable - -'
td() { printf 'app %s /example/log-group ecs\n%s\n' "$1" "$SIDE"; }

rel "service on :master: exits 0" 0 $SVC "$MERGE" $CL $SV
logs "service on :master: reads the service" "$AWS_LOG" "ecs describe-services --cluster $CL --services $SV"
logs "service on :master: reads its task definition" "$AWS_LOG" "ecs describe-task-definition --task-definition td/example-service:7"
logs "service on :master: retagged sha-<7> as master" "$AWS_LOG" "ecr put-image --repository-name $SVC --image-tag master"
logs "service on :master: from sha-<7>" "$AWS_LOG" "ecr batch-get-image --repository-name $SVC --image-ids imageTag=sha-abc1234"
is   "service on :master: digest is the last line" "$(printf '%s\n' "$out" | tail -n 1)" "$A"
logs "service on :master: digest in GITHUB_OUTPUT" "$GITHUB_OUTPUT" "digest=$A"
hasnt "service on :master: no warning or error" "$out$err" "::"
FAKE_TD=$(td "other.registry.test/team/$SVC:master") rel "any registry path to <service>:master: exits 0" 0 $SVC "$MERGE" $CL $SV
logs "any registry path: retagged" "$AWS_LOG" "put-image"

FAKE_TD=$(td "registry.example.test/$SVC@$A") rel "digest-pinned image: exits 3" 3 $SVC "$MERGE" $CL $SV
has  "digest-pinned image: names the image" "$out$err" "registry.example.test/$SVC@$A"
writes "digest-pinned image: no AWS write (no put-image, no update-service)" "$AWS_LOG"
nologs "digest-pinned image: no ECR call" "$AWS_LOG" "ecr "
nologs "digest-pinned image: no digest output" "$GITHUB_OUTPUT" "digest="
FAKE_TD=$(td "registry.example.test/$SVC:latest") rel "other tag: exits 3" 3 $SVC "$MERGE" $CL $SV
has  "other tag: names the image" "$out$err" "registry.example.test/$SVC:latest"
writes "other tag: no AWS write" "$AWS_LOG"
FAKE_TD=$(td "registry.example.test/$SVC") rel "no tag (implicit latest): exits 3" 3 $SVC "$MERGE" $CL $SV
FAKE_TD=$(td "registry.example.test/$SVC-extra:master") rel "only another repository's image: exits 3" 3 $SVC "$MERGE" $CL $SV
has  "another repository: says no container runs the service's repository" "$out$err" "no container"
writes "another repository: no AWS write" "$AWS_LOG"
FAKE_TD=$(td "registry.example.test/$SVC:master"; echo "worker registry.example.test/$SVC:latest - -") rel "two containers of the repository, one not on :master: exits 3" 3 $SVC "$MERGE" $CL $SV
has  "two containers: names the one not on :master" "$out$err" "$SVC:latest"
FAKE_FAIL_OP=describe-services rel "cannot read the service: exits 1" 1 $SVC "$MERGE" $CL $SV
writes "cannot read the service: no AWS write" "$AWS_LOG"
FAKE_FAIL_OP=describe-task-definition rel "cannot read the task definition: exits 1" 1 $SVC "$MERGE" $CL $SV
writes "cannot read the task definition: no AWS write" "$AWS_LOG"

FAKE_SRC_MISSING=1 rel "sha-<7> missing: exits 2" 2 $SVC "$MERGE" $CL $SV
has "sha-<7> missing: says so" "$err" "sha-abc1234"
nologs "sha-<7> missing: no put-image" "$AWS_LOG" "put-image"
nologs "sha-<7> missing: no digest output" "$GITHUB_OUTPUT" "digest="
FAKE_PUT_ERR=ImageAlreadyExistsException rel "re-run (master already on sha-<7>): exits 0" 0 $SVC "$MERGE" $CL $SV
is "re-run: prints the digest" "$(printf '%s\n' "$out" | tail -n 1)" "$A"
rel "usage: three args" 64 $SVC "$MERGE" $CL
rel "usage: short sha" 64 $SVC abc1234 $CL $SV
rel "usage: bad cluster" 64 $SVC "$MERGE" "a cluster" $SV
rel "usage: no args" 64
empty "usage: no aws call" "$AWS_LOG"
exit $status
