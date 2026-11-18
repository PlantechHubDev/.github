#!/usr/bin/env bash
# Tests open-deploy-pr.sh (pin the released digest in an infrastructure-live branch and open the
# deploy PR) and sim-run-url.sh, with the fake gh and aws in scripts/fixtures/deploy-pr/bin first
# on PATH. infrastructure-live is a local bare "origin" plus a clone per case, and the service is a
# local repo with real merge commits, so nothing touches GitHub or AWS.
# Usage: bash scripts/test-open-deploy-pr.sh   (exit 0 when every case passes)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FIX=$HERE/fixtures/deploy-pr
export PATH="$FIX/bin:$PATH"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# An empty global git config, so the developer's signing or hooks never reach these repos.
: > "$T/gitconfig"; export GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1
export AWS_LOG=$T/aws.log GH_LOG=$T/gh.log GH_BODY=$T/body.md GITHUB_STEP_SUMMARY=$T/summary.md
unset FAKE_OPEN_PRS FAKE_GH_CREATE_EXIT FAKE_GH_CLOSE_EXIT FAKE_RUNS FAKE_RUNS_EXIT FAKE_TAG_DIGEST FAKE_AWS_DENIED BASE_DIGEST DRY_RUN SERVICE_GH_TOKEN INFRA_REPO HELD_BY
# release-image.sh's outputs, passed by java-service-release.yml: did :master move, and if not, which units held it.
export RETAGGED=true

SVC=orchestration-service
UNIT=plantechhub/us-east-1/prod/$SVC/terragrunt.hcl
A=sha256:$(printf 'a%.0s' $(seq 64))          # the released (queue) image
C=sha256:$(printf 'c%.0s' $(seq 64))          # the digest prod is pinned to now
SIM=https://github.com/PlantechHubDev/$SVC/actions/runs/42
NEW_URL=https://github.com/PlantechHubDev/infrastructure-live/pull/77
export FAKE_NEW_PR_URL=$NEW_URL DEPLOY_GIT_NAME='pth-ci[bot]' DEPLOY_GIT_EMAIL='1+pth-ci[bot]@users.noreply.github.com'
G() { git -c commit.gpgsign=false -c user.name=t -c user.email=t@example.invalid "$@"; }

# The service: base, PR #10 (deployed), PR #11 (whose branch holds a commit that only looks like a
# merge), a direct commit, PR #12 (the merge commit being released).
S=$T/svc
G init -q -b master "$S"
G -C "$S" commit -q --allow-empty -m "chore: base"
G -C "$S" commit -q --allow-empty -m "Merge pull request #10 from PlantechHubDev/feat-10"
DEPLOYED=$(git -C "$S" rev-parse HEAD)
G -C "$S" checkout -q -b feat-11
G -C "$S" commit -q --allow-empty -m "Merge pull request #99 from inside/a-branch"
G -C "$S" checkout -q master
G -C "$S" merge -q --no-ff feat-11 -m "Merge pull request #11 from PlantechHubDev/feat-11"
G -C "$S" commit -q --allow-empty -m "fix: direct commit"
G -C "$S" commit -q --allow-empty -m "Merge pull request #12 from PlantechHubDev/feat-12"
MERGE=$(git -C "$S" rev-parse HEAD)
S7=${MERGE:0:7}
BR=deploy/$SVC-$S7
export SERVICE_REPO=$S FAKE_COMMIT=$DEPLOYED

status=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; status=1; }

# setup <fixture>: a fresh infrastructure-live origin whose master holds the fixture as the unit
# (plus another unit), and a clone of it at $W.
n=0
setup() {
  n=$((n + 1)); O=$T/origin-$n.git W=$T/work-$n
  local seed=$T/seed-$n
  G init -q -b master "$seed"
  mkdir -p "$seed/$(dirname "$UNIT")" "$seed/plantechhub/us-east-1/prod/calc-service"
  cp "$FIX/$1" "$seed/$UNIT"
  cp "$FIX/terragrunt-master.hcl" "$seed/plantechhub/us-east-1/prod/calc-service/terragrunt.hcl"
  G -C "$seed" add -A && G -C "$seed" commit -q -m "chore: seed"
  G clone -q --bare "$seed" "$O"
  G clone -q "$O" "$W"
}
# run <name> <want-exit> <args...>: open-deploy-pr.sh in $W with fresh logs; stdout in $so,
# stdout+stderr in $out.
run() {
  local name=$1 want=$2; shift 2
  : > "$AWS_LOG"; : > "$GH_LOG"; : > "$GITHUB_STEP_SUMMARY"; rm -f "$GH_BODY"
  (cd "$W" && bash "$HERE/open-deploy-pr.sh" "$@" >"$T/stdout" 2>"$T/stderr"); code=$?
  so=$(cat "$T/stdout"); out=$so$'\n'$(cat "$T/stderr")
  if [ "$code" = "$want" ]; then pass "$name"; else fail "$name" "exit $code want $want; output: $out"; fi
}
has()    { if [[ $2 == *"$3"* ]]; then pass "$1"; else fail "$1" "lacks '$3': $2"; fi; }
hasnt()  { if [[ $2 == *"$3"* ]]; then fail "$1" "has '$3': $2"; else pass "$1"; fi; }
is()     { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got '$2' want '$3'"; fi; }
logs()   { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1" "$(basename "$2") lacks '$3': $(cat "$2")"; fi; }
nologs() { if grep -qF -- "$3" "$2"; then fail "$1" "$(basename "$2") has '$3'"; else pass "$1"; fi; }
body()   { cat "$GH_BODY" 2>/dev/null; }
# golden <name> <fixture>: the PR body equals scripts/fixtures/deploy-pr/<fixture> exactly, with
# @MERGE@, @S7@ and @DEPLOYED7@ filled in.
golden() {
  local d
  if d=$(diff <(sed -e "s/@MERGE@/$MERGE/g" -e "s/@S7@/$S7/g" -e "s/@DEPLOYED7@/${DEPLOYED:0:7}/g" "$FIX/$2") "$GH_BODY" 2>&1); then
    pass "$1"
  else
    fail "$1" "body differs from $2: $d"
  fi
}
# remote_file <ref>: the unit file at <ref> in the origin.
remote_file() { git -C "$O" show "$1:$UNIT" 2>/dev/null; }
no_branch() { if git -C "$O" rev-parse -q --verify "refs/heads/$BR" >/dev/null; then fail "$1" "origin has $BR"; else pass "$1"; fi; }

# --- :master form, rollback digest from BASE_DIGEST (resolved before the retag)
setup terragrunt-master.hcl
RETAGGED=false HELD_BY="$UNIT plantechhub/us-west-2/prod/$SVC/terragrunt.hcl" BASE_DIGEST=$C run "master form: exits 0" 0 $SVC "$A" "$MERGE" "$SIM"
golden "master form, not retagged: golden PR body (says :master was not moved, names the units)" body-not-retagged.md
if diff <(remote_file "$BR") "$FIX/terragrunt-expected.hcl" >/dev/null; then pass "master form: unit pinned to the digest, other lines unchanged"; else fail "master form: unit pinned" "$(diff <(remote_file "$BR") "$FIX/terragrunt-expected.hcl")"; fi
if diff <(remote_file master) "$FIX/terragrunt-master.hcl" >/dev/null; then pass "master form: origin master untouched"; else fail "master form: origin master untouched" "master changed"; fi
if diff <(git -C "$O" show "$BR:plantechhub/us-east-1/prod/calc-service/terragrunt.hcl") "$FIX/terragrunt-master.hcl" >/dev/null; then pass "master form: other unit untouched"; else fail "master form: other unit untouched" "calc-service changed"; fi
is  "master form: one commit on the branch" "$(git -C "$O" rev-list --count "master..$BR")" 1
is  "master form: commit subject" "$(git -C "$O" log -1 --format=%s "$BR")" "deploy($SVC): pin $S7"
is  "master form: commit body is empty (no attribution)" "$(git -C "$O" log -1 --format=%b "$BR")" ""
is  "master form: commit author is the App bot" "$(git -C "$O" log -1 --format='%an <%ae>' "$BR")" "pth-ci[bot] <1+pth-ci[bot]@users.noreply.github.com>"
is  "master form: committer is the App bot" "$(git -C "$O" log -1 --format='%cn' "$BR")" "pth-ci[bot]"
logs "master form: PR created into master on the deploy branch" "$GH_LOG" "pr create -R PlantechHubDev/infrastructure-live --base master --head $BR --title deploy($SVC): $S7"
is  "master form: stdout is only the PR URL" "$so" "$NEW_URL"
logs "master form: step summary names the PR" "$GITHUB_STEP_SUMMARY" "$NEW_URL"
has "body: rollback digest is the old pin" "$(body)" "Rollback digest: $C"
has "body: names the new image by digest" "$(body)" "registry.example.test/$SVC@$A"
has "body: simulation link" "$(body)" "$SIM"
has "body: lists PR #11" "$(body)" "PlantechHubDev/$SVC#11"
has "body: lists PR #12" "$(body)" "PlantechHubDev/$SVC#12"
hasnt "body: not the deployed PR #10" "$(body)" "#10"
hasnt "body: not a merge-looking commit off the first parent (#99)" "$(body)" "#99"
has "body: names the merge commit" "$(body)" "$MERGE"
logs "deployed commit looked up from the rollback digest" "$AWS_LOG" "ecr describe-images --repository-name $SVC --image-ids imageDigest=$C"

# --- tag pin whose digest is already the new image (:master moved before a re-run): refuse
setup terragrunt-master.hcl
BASE_DIGEST=$A run "rollback equals new digest: exits 1" 1 $SVC "$A" "$MERGE" "$SIM"
has "rollback equals new digest: says why" "$out" "rollback digest is the new image"
nologs "rollback equals new digest: no PR" "$GH_LOG" "pr create"
no_branch "rollback equals new digest: nothing pushed"
W=$T/work-1 O=$T/origin-1.git

# --- re-run with a :master pin (the retag was skipped, so :master and BASE_DIGEST are unchanged):
# idempotent, it reuses the branch and the PR, adds no commit, closes nothing of ours
G clone -q "$O" "$T/work-rerun"; W=$T/work-rerun
FAKE_OPEN_PRS="[{\"number\":8,\"headRefName\":\"$BR\",\"url\":\"$NEW_URL\"}]" BASE_DIGEST=$C run "re-run: exits 0" 0 $SVC "$A" "$MERGE" "$SIM"
is  "re-run: still one commit on the branch" "$(git -C "$O" rev-list --count "master..$BR")" 1
nologs "re-run: no second PR" "$GH_LOG" "pr create"
logs "re-run: existing PR body updated" "$GH_LOG" "pr edit 8 -R PlantechHubDev/infrastructure-live"
nologs "re-run: own PR not closed" "$GH_LOG" "pr close 8"
has "re-run: body written" "$(body)" "Rollback digest: $C"
is  "re-run: stdout is the existing PR URL" "$so" "$NEW_URL"

# --- re-run where the branch holds another commit: it is reused and fast-forwarded
setup terragrunt-master.hcl
G -C "$W" checkout -q -b "$BR" && echo note > "$W/NOTE" && G -C "$W" add NOTE && G -C "$W" commit -q -m "docs: note" && G -C "$W" push -q origin "$BR" && G -C "$W" checkout -q master
BASE_DIGEST=$C run "existing branch: exits 0 (no force-push)" 0 $SVC "$A" "$MERGE" "$SIM"
is "existing branch: earlier commit kept" "$(git -C "$O" log --format=%s "master..$BR" | tail -n 1)" "docs: note"
if diff <(remote_file "$BR") "$FIX/terragrunt-expected.hcl" >/dev/null; then pass "existing branch: unit pinned"; else fail "existing branch: unit pinned" "unit differs"; fi

# --- @sha256 form: rollback digest read from the file
setup terragrunt-digest.hcl
run "digest form: exits 0" 0 $SVC "$A" "$MERGE" "$SIM"
if diff <(remote_file "$BR") "$FIX/terragrunt-expected.hcl" >/dev/null; then pass "digest form: unit rewritten, other lines unchanged"; else fail "digest form: unit rewritten" "$(diff <(remote_file "$BR") "$FIX/terragrunt-expected.hcl")"; fi
has "digest form: rollback digest is the old digest" "$(body)" "Rollback digest: $C"
golden "digest form, retagged: golden PR body (says retagged as :master without rebuilding)" body-retagged.md
hasnt "digest form, retagged: does not say :master was not moved" "$(body)" "not moved"

# --- older deploy PRs of this service are closed, others untouched
setup terragrunt-digest.hcl
FAKE_OPEN_PRS='[{"number":5,"headRefName":"deploy/orchestration-service-abc1234","url":"u5"},
 {"number":6,"headRefName":"deploy/calc-service-abc1234","url":"u6"},
 {"number":7,"headRefName":"deploy/orchestration-service-extra-abc1234","url":"u7"},
 {"number":9,"headRefName":"feature/deploy/orchestration-service-abc1234","url":"u9"}]' \
  run "supersede: exits 0" 0 $SVC "$A" "$MERGE" "$SIM"
logs "supersede: older PR closed with a comment naming the new PR" "$GH_LOG" "pr close 5 -R PlantechHubDev/infrastructure-live --comment Superseded by $NEW_URL"
nologs "supersede: other service's PR untouched" "$GH_LOG" "pr close 6"
nologs "supersede: longer service name with the same prefix untouched" "$GH_LOG" "pr close 7"
nologs "supersede: non-deploy branch untouched" "$GH_LOG" "pr close 9"
has "supersede: body keeps the rollback digest" "$(body)" "Rollback digest: $C"

# --- PRs from forks are never closed or reused, even on a deploy/ branch name
setup terragrunt-digest.hcl
FAKE_OPEN_PRS='[{"number":5,"headRefName":"deploy/orchestration-service-abc1234","url":"u5","isCrossRepository":true,"headRepositoryOwner":{"login":"someone"}},
 {"number":8,"headRefName":"'"$BR"'","url":"u8","isCrossRepository":true,"headRepositoryOwner":{"login":"someone"}},
 {"number":4,"headRefName":"deploy/orchestration-service-def5678","url":"u4","isCrossRepository":false,"headRepositoryOwner":{"login":"PlantechHubDev"}}]' \
  run "fork: exits 0" 0 $SVC "$A" "$MERGE" "$SIM"
nologs "fork: fork PR on an older deploy branch not closed" "$GH_LOG" "pr close 5"
nologs "fork: fork PR on this branch name not reused" "$GH_LOG" "pr edit 8"
logs "fork: our own PR is created instead" "$GH_LOG" "pr create"
logs "fork: same-repo older deploy PR still closed" "$GH_LOG" "pr close 4 "

# --- closing an older PR fails: exit 1, the new PR is open and the summary says which failed
setup terragrunt-digest.hcl
FAKE_GH_CLOSE_EXIT=1 FAKE_OPEN_PRS='[{"number":5,"headRefName":"deploy/orchestration-service-abc1234","url":"u5"}]' \
  run "close failure: exits 1" 1 $SVC "$A" "$MERGE" "$SIM"
is  "close failure: stdout still the new PR URL" "$so" "$NEW_URL"
logs "close failure: summary names the open PR" "$GITHUB_STEP_SUMMARY" "$NEW_URL"
logs "close failure: summary names the PR not closed" "$GITHUB_STEP_SUMMARY" "#5"

# --- no image line: exit 2, nothing opened or pushed
setup terragrunt-noimage.hcl
BASE_DIGEST=$C run "no image line: exits 2" 2 $SVC "$A" "$MERGE" "$SIM"
nologs "no image line: no PR created" "$GH_LOG" "pr create"
no_branch "no image line: nothing pushed"
setup terragrunt-twoimage.hcl
BASE_DIGEST=$C run "two image lines: exits 2" 2 $SVC "$A" "$MERGE" "$SIM"
nologs "two image lines: no PR created" "$GH_LOG" "pr create"
setup terragrunt-wrongrepo.hcl
BASE_DIGEST=$C run "image of another repository: exits 2" 2 $SVC "$A" "$MERGE" "$SIM"
setup terragrunt-master.hcl
rm "$W/$UNIT"; G -C "$W" commit -q -am "chore: drop unit"; G -C "$W" push -q origin master
BASE_DIGEST=$C run "unit file missing: exits 2" 2 $SVC "$A" "$MERGE" "$SIM"

# --- already pinned to this digest: nothing to deploy
setup terragrunt-expected.hcl
run "already pinned: exits 0" 0 $SVC "$A" "$MERGE" "$SIM"
has "already pinned: says so" "$out" "already pinned"
is  "already pinned: nothing on stdout" "$so" ""
logs "already pinned: step summary says no PR" "$GITHUB_STEP_SUMMARY" "already pinned"
nologs "already pinned: no PR" "$GH_LOG" "pr create"
no_branch "already pinned: nothing pushed"

# --- push rejected: exit 1, no PR
setup terragrunt-digest.hcl
printf '#!/bin/sh\necho "rejected by test hook" >&2\nexit 1\n' > "$O/hooks/pre-receive"; chmod +x "$O/hooks/pre-receive"
run "push rejected: exits 1" 1 $SVC "$A" "$MERGE" "$SIM"
has "push rejected: says the push failed" "$out" "cannot push $BR"
nologs "push rejected: no PR created" "$GH_LOG" "pr create"

# --- DRY_RUN=1: prints branch, diff and body; pushes, creates and closes nothing
setup terragrunt-digest.hcl
FAKE_OPEN_PRS='[{"number":5,"headRefName":"deploy/orchestration-service-abc1234","url":"u5"}]' \
  DRY_RUN=1 DEPLOY_GIT_NAME='' run "dry run: exits 0 (no bot identity needed)" 0 $SVC "$A" "$MERGE" "$SIM"
has "dry run: prints the branch" "$out" "$BR"
has "dry run: prints the diff" "$out" "+    image          = \"registry.example.test/$SVC@$A\""
has "dry run: prints the body" "$out" "Rollback digest: $C"
has "dry run: names what it would close" "$out" "would close #5"
no_branch "dry run: nothing pushed"
nologs "dry run: no PR created" "$GH_LOG" "pr create"
nologs "dry run: nothing closed" "$GH_LOG" "pr close"
nologs "dry run: nothing edited" "$GH_LOG" "pr edit"

# --- the deployed commit is not in the service history: the PR still opens, with a note
setup terragrunt-digest.hcl
FAKE_COMMIT=$(printf 'f%.0s' $(seq 40)) run "unknown deployed commit: exits 0" 0 $SVC "$A" "$MERGE" "$SIM"
has "unknown deployed commit: body says the PRs could not be listed" "$(body)" "could not list"
setup terragrunt-digest.hcl
run "simulation not found: exits 0" 0 $SVC "$A" "$MERGE" "simulation run: not found"
has "simulation not found: body says so" "$(body)" "simulation run: not found"

setup terragrunt-digest.hcl
RETAGGED=false HELD_BY='' run "not retagged, no units named: exits 0" 0 $SVC "$A" "$MERGE" "$SIM"
has "not retagged, no units named: still says :master was not moved" "$(body)" "\`:master\` was not moved, because a prod unit pins \`:master\` or could not be read, so this PR pins the image by digest."

# --- usage (64)
setup terragrunt-master.hcl
run "usage: no args" 64
run "usage: bad digest" 64 $SVC "sha256:abc" "$MERGE" "$SIM"
run "usage: short merge sha" 64 $SVC "$A" "$S7" "$SIM"
run "usage: empty sim url" 64 $SVC "$A" "$MERGE" ""
run "usage: bad service" 64 "Orch/x" "$A" "$MERGE" "$SIM"
run "usage: master form needs BASE_DIGEST" 64 $SVC "$A" "$MERGE" "$SIM"
has "usage: says BASE_DIGEST is needed" "$out" "BASE_DIGEST"
DEPLOY_GIT_NAME='' BASE_DIGEST=$C run "usage: no bot identity" 64 $SVC "$A" "$MERGE" "$SIM"
RETAGGED='' BASE_DIGEST=$C run "usage: RETAGGED unset" 64 $SVC "$A" "$MERGE" "$SIM"
has "usage: says RETAGGED is needed" "$out" "RETAGGED"
RETAGGED=yes BASE_DIGEST=$C run "usage: RETAGGED not true|false" 64 $SVC "$A" "$MERGE" "$SIM"
SERVICE_REPO=$T/nowhere BASE_DIGEST=$C run "usage: SERVICE_REPO not a repo" 64 $SVC "$A" "$MERGE" "$SIM"
nologs "usage: no PR created" "$GH_LOG" "pr create"
no_branch "usage: nothing pushed"

# --- --base-digest: the digest prod is pinned to on origin master (before the retag)
setup terragrunt-digest.hcl
run "base: digest form exits 0" 0 --base-digest $SVC
is "base: digest form prints the pinned digest and the pin kind" "$so" "$C digest"
nologs "base: digest form needs no aws" "$AWS_LOG" "ecr"
setup terragrunt-master.hcl
FAKE_TAG_DIGEST=$C run "base: tag form exits 0" 0 --base-digest $SVC
is "base: tag form prints the tag's digest and the tag" "$so" "$C tag:master"
logs "base: tag resolved in ECR" "$AWS_LOG" "ecr describe-images --repository-name $SVC --image-ids imageTag=master"
run "base: tag not in ECR exits 2" 2 --base-digest $SVC
FAKE_AWS_DENIED=1 run "base: aws failure exits 1" 1 --base-digest $SVC
setup terragrunt-noimage.hcl
run "base: no image line exits 2" 2 --base-digest $SVC
run "base: usage" 64 --base-digest

# --- --pins: every prod unit of the service, in every region, from origin master
WEST=plantechhub/us-west-2/prod/$SVC/terragrunt.hcl
# add_unit <path> <fixture>: commit <fixture> at <path> on origin master (through $W).
add_unit() { mkdir -p "$W/$(dirname "$1")"; cp "$FIX/$2" "$W/$1"; G -C "$W" add -A; G -C "$W" commit -q -m "chore: add $1"; G -C "$W" push -q origin master; }
setup terragrunt-digest.hcl
add_unit "$WEST" terragrunt-dr-master.hcl
add_unit plantechhub/us-west-2/prod/calc-service/terragrunt.hcl terragrunt-dr-master.hcl
add_unit "plantechhub/us-east-1/staging/$SVC/terragrunt.hcl" terragrunt-master.hcl
add_unit "plantechhub/us-east-1/prod/$SVC-extra/terragrunt.hcl" terragrunt-master.hcl
run "pins: exits 0" 0 --pins $SVC
is "pins: one line per prod unit, all regions, with its pin" "$so" "plantechhub/us-east-1/prod/$SVC/terragrunt.hcl digest
$WEST tag:master"
nologs "pins: no aws call" "$AWS_LOG" "ecr"
# --pins | release-image.sh: the DR unit's :master pin stops the retag.
: > "$AWS_LOG"
pipe=$( (cd "$W" && bash "$HERE/open-deploy-pr.sh" --pins $SVC) | FAKE_TAG_DIGEST=$A FAKE_SRC_DIGEST=$A GITHUB_OUTPUT=$T/out bash "$HERE/release-image.sh" $SVC "$MERGE" 2>&1)
nologs "pins | release-image: no put-image while us-west-2 pins :master" "$AWS_LOG" "put-image"
has "pins | release-image: warning names the us-west-2 unit" "$pipe" "$WEST"
setup terragrunt-digest.hcl
add_unit "$WEST" terragrunt-digest.hcl
run "pins: all digests exits 0" 0 --pins $SVC
is "pins: all digests" "$so" "plantechhub/us-east-1/prod/$SVC/terragrunt.hcl digest
$WEST digest"
setup terragrunt-digest.hcl
add_unit "$WEST" terragrunt-noimage.hcl
run "pins: unparseable unit exits 0" 0 --pins $SVC
is "pins: unparseable unit reported, not dropped" "$so" "plantechhub/us-east-1/prod/$SVC/terragrunt.hcl digest
$WEST unparseable"
setup terragrunt-digest.hcl
G -C "$W" rm -q -r plantechhub; G -C "$W" commit -q -m "chore: drop"; G -C "$W" push -q origin master
run "pins: no prod unit exits 2" 2 --pins $SVC
run "pins: usage" 64 --pins

# --- sim-run-url.sh: the merge_group run of the caller's CI workflow for the merged commit
sim() { : > "$GH_LOG"; out=$(bash "$HERE/sim-run-url.sh" "$@" 2>/dev/null); code=$?; }
FAKE_RUNS='{"workflow_runs":[
 {"path":".github/workflows/other.yml","head_sha":"'"$MERGE"'","html_url":"https://x/other"},
 {"path":".github/workflows/ci.yml","head_sha":"'"$MERGE"'","html_url":"'"$SIM"'"}]}' sim "PlantechHubDev/$SVC" "$MERGE" ci.yml
is "sim: exits 0" "$code" 0
is "sim: prints the CI workflow's run" "$out" "$SIM"
logs "sim: queries merge_group runs for the commit" "$GH_LOG" "api repos/PlantechHubDev/$SVC/actions/runs?event=merge_group&head_sha=$MERGE"
FAKE_RUNS='{"workflow_runs":[{"path":".github/workflows/ci.yml","head_sha":"0000000","html_url":"https://x/wrong"}]}' sim "PlantechHubDev/$SVC" "$MERGE" ci.yml
is "sim: another commit's run is not taken" "$out" "simulation run: not found"
sim "PlantechHubDev/$SVC" "$MERGE" ci.yml
is "sim: no run prints not found" "$out" "simulation run: not found"
is "sim: no run still exits 0" "$code" 0
FAKE_RUNS_EXIT=1 sim "PlantechHubDev/$SVC" "$MERGE" ci.yml
is "sim: gh failure prints not found" "$out" "simulation run: not found"
is "sim: gh failure still exits 0" "$code" 0
sim "PlantechHubDev/$SVC" "$MERGE"
is "sim: usage exits 64" "$code" 64
exit $status
