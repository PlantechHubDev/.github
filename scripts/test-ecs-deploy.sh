#!/usr/bin/env bash
# Tests the release's green gate and deploy scripts with the fake aws and gh in
# scripts/fixtures/ecs-deploy/bin first on PATH, so nothing touches GitHub or AWS:
#   queue-run-green.sh   the queue's merge_group run for the merged commit was green
#   ecs-deploy.sh        force a new deployment, wait for services-stable, compare running digests
#   post-deploy-checks.sh  digest, deployment COMPLETED, no ERROR logs since, no alarm in ALARM
#   deploy-comment.sh    comment on each service PR the deploy carries
# plus a re-run of a whole release on the same merge (release-image.sh then ecs-deploy.sh).
# Usage: bash scripts/test-ecs-deploy.sh   (exit 0 when every case passes)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH="$HERE/fixtures/ecs-deploy/bin:$PATH"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
: > "$T/gitconfig"; export GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1
export AWS_LOG=$T/aws.log GH_LOG=$T/gh.log FAKE_STATE=$T/state
mkdir -p "$FAKE_STATE"
unset FAKE_RUNS FAKE_RUNS_EXIT FAKE_JOBS FAKE_JOBS_EXIT FAKE_TASKS FAKE_PREV_TASKS FAKE_UPDATE_ERR \
  FAKE_WAIT_FAIL FAKE_ROLLOUT FAKE_RUNNING FAKE_DESIRED FAKE_LOG_EVENTS FAKE_ALARMS FAKE_FAIL_OP \
  FAKE_AWS_DENIED FAKE_COMMENT_EXIT FAKE_SRC_MISSING FAKE_PUT_ERR FAKE_TAG_DIGEST GITHUB_OUTPUT GITHUB_STEP_SUMMARY
SVC=example-service
REPO=PlantechHubDev/$SVC
A=sha256:$(printf 'a%.0s' $(seq 64))   # the released image
B=sha256:$(printf 'b%.0s' $(seq 64))   # another image (the previous one)
L=sha256:$(printf 'f%.0s' $(seq 64))   # a sidecar's image
MERGE=abc1234$(printf '0%.0s' $(seq 33))
OTHER=def5678$(printf '0%.0s' $(seq 33))
status=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; status=1; }
is()     { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got '$2' want '$3'"; fi; }
has()    { if [[ $2 == *"$3"* ]]; then pass "$1"; else fail "$1" "lacks '$3': $2"; fi; }
hasnt()  { if [[ $2 == *"$3"* ]]; then fail "$1" "has '$3': $2"; else pass "$1"; fi; }
logs()   { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1" "$(basename "$2") lacks '$3': $(cat "$2")"; fi; }
nologs() { if grep -qF -- "$3" "$2"; then fail "$1" "$(basename "$2") has '$3'"; else pass "$1"; fi; }
empty()  { if [ -s "$2" ]; then fail "$1" "$(basename "$2") not empty: $(cat "$2")"; else pass "$1"; fi; }
count()  { local n; n=$(grep -cF -- "$3" "$2"); if [ "$n" = "$4" ]; then pass "$1"; else fail "$1" "$(basename "$2") has '$3' $n times, want $4: $(cat "$2")"; fi; }
# run <name> <want-exit> <script> <args...>: fresh logs and state; stdout in $out, stderr in $err.
run() {
  local name=$1 want=$2 script=$3; shift 3
  : > "$AWS_LOG"; : > "$GH_LOG"; rm -f "$FAKE_STATE/updated"
  out=$(bash "$HERE/$script" "$@" 2>"$T/err"); code=$?; err=$(cat "$T/err")
  if [ "$code" = "$want" ]; then pass "$name"; else fail "$name" "exit $code want $want; stdout '$out' stderr '$err'"; fi
}

# ---------------------------------------------------------------- queue-run-green.sh
# run_json <id> <sha> <conclusion> [path]: one merge_group run.
run_json() {
  printf '{"id":%s,"path":"%s","head_sha":"%s","event":"merge_group","status":"completed","conclusion":"%s","html_url":"https://github.com/%s/actions/runs/%s"}' \
    "$1" "${4:-.github/workflows/ci.yml}" "$2" "$3" "$REPO" "$1"
}
runs() { local IFS=,; echo "{\"workflow_runs\":[$*]}"; }
# job <name> <conclusion>
job() { printf '{"name":"%s","status":"completed","conclusion":"%s"}' "$1" "$2"; }
jobs() { local IFS=,; echo "{\"jobs\":[$*]}"; }
# The jobs of a green queue run of the README's trunk ci.yml: called workflows' jobs appear as
# "<caller job> / <job>"; image's build is skipped when sha-<7> already exists.
GREEN_JOBS=("$(job 'checks / secret-scan' success)" "$(job 'checks / commit-lint' success)"
  "$(job 'test / test' success)" "$(job 'paired-tests / check' success)"
  "$(job 'image / check' success)" "$(job 'image / build' skipped)" "$(job 'image / result' success)"
  "$(job 'pth-sim / pth-sim' success)" "$(job 'ci-ok' success)")
# green_but <job name> <conclusion>: GREEN_JOBS with that job's conclusion replaced.
green_but() {
  local j list=()
  for j in "${GREEN_JOBS[@]}"; do
    if [[ $j == *"\"name\":\"$1\""* ]]; then list+=("$(job "$1" "$2")"); else list+=("$j"); fi
  done
  jobs "${list[@]}"
}

export FAKE_RUNS FAKE_JOBS
FAKE_RUNS=$(runs "$(run_json 11 "$MERGE" success)")
FAKE_JOBS=$(jobs "${GREEN_JOBS[@]}")
run "green: exits 0" 0 queue-run-green.sh "$REPO" "$MERGE" ci.yml
is  "green: prints the run URL" "$out" "https://github.com/$REPO/actions/runs/11"
logs "green: lists merge_group runs for the merged sha" "$GH_LOG" "api repos/$REPO/actions/runs?event=merge_group&head_sha=$MERGE"
logs "green: reads that run's jobs" "$GH_LOG" "api repos/$REPO/actions/runs/11/jobs"
empty "green: no aws call" "$AWS_LOG"

# A job skipped by its own if: for another event (here an extra job) is allowed.
FAKE_JOBS=$(jobs "${GREEN_JOBS[@]}" "$(job 'docs / preview' skipped)")
run "green: another job skipped is allowed" 0 queue-run-green.sh "$REPO" "$MERGE" ci.yml

for c in failure cancelled; do
  FAKE_JOBS=$(jobs "${GREEN_JOBS[@]}" "$(job 'docs / preview' "$c")")
  run "not green: an unrelated job $c exits 1" 1 queue-run-green.sh "$REPO" "$MERGE" ci.yml
  has "not green: names the $c job" "$err" "docs / preview"
  empty "not green ($c job): no aws call (no put-image, no update-service)" "$AWS_LOG"
done
for name in 'ci-ok' 'image / result' 'pth-sim / pth-sim'; do
  for c in failure cancelled; do
    FAKE_JOBS=$(green_but "$name" "$c")
    run "not green: $name $c exits 1" 1 queue-run-green.sh "$REPO" "$MERGE" ci.yml
    has "not green: $name $c is named" "$err" "$name"
    empty "not green ($name $c): no aws call" "$AWS_LOG"
  done
done
# A caller job skipped by its if: shows as one job with the caller job's name, conclusion skipped.
# green_skip <group>: GREEN_JOBS with the group's jobs replaced by that one skipped job.
green_skip() {
  local j list=()
  for j in "${GREEN_JOBS[@]}"; do
    [[ $j == *"\"name\":\"$1\""* || $j == *"\"name\":\"$1 / "* ]] || list+=("$j")
  done
  jobs "${list[@]}" "$(job "$1" skipped)"
}
for g in ci-ok image pth-sim; do
  FAKE_JOBS=$(green_skip "$g")
  run "not green: $g skipped exits 1" 1 queue-run-green.sh "$REPO" "$MERGE" ci.yml
  has "not green: $g skipped is named" "$err" "$g"
  empty "not green ($g skipped): no aws call (no put-image, no update-service)" "$AWS_LOG"
done
# A required job missing from the run altogether.
FAKE_JOBS=$(jobs "$(job 'checks / secret-scan' success)" "$(job 'image / result' success)" "$(job 'ci-ok' success)")
run "not green: no pth-sim job exits 1" 1 queue-run-green.sh "$REPO" "$MERGE" ci.yml
has "not green: says pth-sim is missing" "$err" "pth-sim"
FAKE_JOBS=$(jobs "${GREEN_JOBS[@]}")
FAKE_RUNS=$(runs "$(run_json 11 "$MERGE" failure)")
run "not green: run concluded failure exits 1" 1 queue-run-green.sh "$REPO" "$MERGE" ci.yml
has "not green: names the run's conclusion" "$err" "failure"
FAKE_RUNS='{"workflow_runs":[{"id":11,"path":".github/workflows/ci.yml","head_sha":"'"$MERGE"'","event":"merge_group","status":"in_progress","conclusion":null,"html_url":"https://x/11"}]}'
run "not green: run still in progress exits 1" 1 queue-run-green.sh "$REPO" "$MERGE" ci.yml
FAKE_RUNS=$(runs "$(run_json 11 "$MERGE" success)")
FAKE_JOBS_EXIT=1 run "jobs lookup fails exits 1" 1 queue-run-green.sh "$REPO" "$MERGE" ci.yml

FAKE_RUNS='{"workflow_runs":[]}'
run "no run for the sha exits 2" 2 queue-run-green.sh "$REPO" "$MERGE" ci.yml
empty "no run: no aws call" "$AWS_LOG"
FAKE_RUNS=$(runs "$(run_json 12 "$OTHER" success)")
run "only a run for another sha exits 2" 2 queue-run-green.sh "$REPO" "$MERGE" ci.yml
empty "other sha: no aws call" "$AWS_LOG"
FAKE_RUNS=$(runs "$(run_json 13 "$MERGE" success .github/workflows/other.yml)")
run "only another workflow's run exits 2" 2 queue-run-green.sh "$REPO" "$MERGE" ci.yml
FAKE_RUNS_EXIT=1 run "runs lookup fails exits 2" 2 queue-run-green.sh "$REPO" "$MERGE" ci.yml
# Newest first: a re-queued commit's latest run decides.
FAKE_RUNS=$(runs "$(run_json 21 "$MERGE" success)" "$(run_json 20 "$MERGE" failure)")
run "newest run of the sha decides" 0 queue-run-green.sh "$REPO" "$MERGE" ci.yml
logs "newest run: reads run 21's jobs" "$GH_LOG" "actions/runs/21/jobs"
FAKE_RUNS=$(runs "$(run_json 31 "$MERGE" success .github/workflows/ci.yml@refs/heads/gh-readonly-queue/master/x)")
run "workflow path with an @ref suffix is found" 0 queue-run-green.sh "$REPO" "$MERGE" ci.yml

run "usage: no args" 64 queue-run-green.sh
run "usage: short sha" 64 queue-run-green.sh "$REPO" abc1234 ci.yml
run "usage: bad repo" 64 queue-run-green.sh "not a repo" "$MERGE" ci.yml
run "usage: bad workflow" 64 queue-run-green.sh "$REPO" "$MERGE" ci
empty "usage: no gh call" "$GH_LOG"
unset FAKE_RUNS FAKE_JOBS

# ---------------------------------------------------------------- ecs-deploy.sh
export FAKE_TASKS FAKE_PREV_TASKS GITHUB_OUTPUT=$T/output
CL=example-cluster SV=example-service-prod
FAKE_PREV_TASKS="t1 $B $L"$'\n'"t2 $B $L"
FAKE_TASKS="t3 $A $L"$'\n'"t4 $A $L"
: > "$GITHUB_OUTPUT"
run "deploy: exits 0" 0 ecs-deploy.sh "$CL" "$SV" "$A"
is   "deploy: prints deployed <digest>" "$(printf '%s\n' "$out" | tail -n 1)" "deployed $A"
logs "deploy: forces a new deployment of the service" "$AWS_LOG" "ecs update-service --cluster $CL --service $SV --force-new-deployment"
logs "deploy: waits for services-stable" "$AWS_LOG" "ecs wait services-stable --cluster $CL --services $SV"
logs "deploy: reads the running tasks" "$AWS_LOG" "ecs list-tasks --cluster $CL --service-name $SV --desired-status RUNNING"
logs "deploy: previous digest in GITHUB_OUTPUT (the :master container, not the sidecar)" "$GITHUB_OUTPUT" "previous-digest=$B"
is   "deploy: update before wait" "$(grep -oE 'update-service|wait services-stable' "$AWS_LOG" | tr '\n' ,)" "update-service,wait services-stable,"
nologs "deploy: no ECR call" "$AWS_LOG" "ecr "

FAKE_WAIT_FAIL=1 run "deploy: services-stable fails exits 1" 1 ecs-deploy.sh "$CL" "$SV" "$A"
has "deploy: says the service did not become stable" "$err" "stable"
FAKE_UPDATE_ERR=ServiceNotFoundException run "deploy: update-service fails exits 1" 1 ecs-deploy.sh "$CL" "$SV" "$A"
nologs "deploy: update failed, no wait" "$AWS_LOG" "wait services-stable"
FAKE_FAIL_OP=list-tasks run "deploy: cannot read tasks exits 1" 1 ecs-deploy.sh "$CL" "$SV" "$A"
FAKE_TASKS="t3 $A $L"$'\n'"t4 $B $L" run "deploy: a task on another digest exits 4" 4 ecs-deploy.sh "$CL" "$SV" "$A"
has "deploy: names the task" "$err" "t4"
has "deploy: names the digest it runs" "$err" "$B"
FAKE_TASKS="" run "deploy: no running task exits 4" 4 ecs-deploy.sh "$CL" "$SV" "$A"
run "deploy usage: no args" 64 ecs-deploy.sh
run "deploy usage: bad digest" 64 ecs-deploy.sh "$CL" "$SV" sha256:abc
run "deploy usage: empty cluster" 64 ecs-deploy.sh "" "$SV" "$A"
empty "deploy usage: no aws call" "$AWS_LOG"

# --- Re-run on the same merge: sha-<7> and master already name the image, prod already runs it.
MERGE_OUT=$T/rerun-output
: > "$MERGE_OUT"
: > "$AWS_LOG"; rm -f "$FAKE_STATE/updated"
EAST=live/region-a/prod/$SVC/terragrunt.hcl
WEST=live/region-b/prod/$SVC/terragrunt.hcl
rerun=$(printf '%s\n%s\n' "$EAST tag:master" "$WEST tag:master" | FAKE_SRC_DIGEST=$A FAKE_PUT_ERR=ImageAlreadyExistsException GITHUB_OUTPUT=$MERGE_OUT bash "$HERE/release-image.sh" $SVC "$MERGE" 2>"$T/err"); rc=$?
is "re-run: release-image exits 0 (tags already present)" "$rc" 0
is "re-run: release-image prints the digest" "$(printf '%s\n' "$rerun" | tail -n 1)" "$A"
rc=0; FAKE_PREV_TASKS="t3 $A"$'\n'"t4 $A" FAKE_TASKS="t5 $A"$'\n'"t6 $A" GITHUB_OUTPUT=$MERGE_OUT bash "$HERE/ecs-deploy.sh" "$CL" "$SV" "$A" >"$T/out" 2>"$T/err" || rc=$?
is "re-run: ecs-deploy exits 0" "$rc" 0
logs "re-run: the deployment is forced again" "$AWS_LOG" "ecs update-service --cluster $CL --service $SV --force-new-deployment"
logs "re-run: previous digest is the image itself" "$MERGE_OUT" "previous-digest=$A"
unset FAKE_TASKS FAKE_PREV_TASKS

# ---------------------------------------------------------------- post-deploy-checks.sh
export FAKE_TASKS="t3 $A $L"$'\n'"t4 $A $L" FAKE_LOG_EVENTS FAKE_ALARMS
SINCE=2026-11-18T12:00:00Z
SINCE_MS=1795003200000
LG=/example/log-group AP=example-service-prod-
FAKE_LOG_EVENTS="$((SINCE_MS - 1000)) ERROR before the deploy"$'\n'"$((SINCE_MS + 1000)) INFO started"
FAKE_ALARMS="${AP}cpu:OK ${AP}5xx:INSUFFICIENT_DATA other-service-prod-cpu:ALARM"
pdc() { run "$1" "$2" post-deploy-checks.sh "${@:3}"; }
ARGS=("$CL" "$SV" "$A" "$SINCE" "$LG" "$AP")
pdc "checks: all pass exits 0" 0 "${ARGS[@]}"
has "checks: says each check passed" "$out" "deployment COMPLETED"
hasnt "checks: all pass: no FAIL line" "$out" "FAIL "
logs "checks: reads the service" "$AWS_LOG" "ecs describe-services --cluster $CL --services $SV"
logs "checks: reads ERROR lines since <since> (epoch ms)" "$AWS_LOG" "logs filter-log-events --log-group-name $LG --start-time $SINCE_MS --filter-pattern ERROR"
logs "checks: reads the service's alarms" "$AWS_LOG" "cloudwatch describe-alarms --alarm-name-prefix $AP"
empty "checks: reads only (no gh)" "$GH_LOG"
nologs "checks: changes nothing" "$AWS_LOG" "update-service"

FAKE_TASKS="t3 $A $L"$'\n'"t4 $B $L" pdc "checks: one task on another digest exits 1" 1 "${ARGS[@]}"
has "checks: names the task on another digest" "$out$err" "t4"
FAKE_TASKS="" pdc "checks: no running task exits 1" 1 "${ARGS[@]}"
FAKE_ROLLOUT=IN_PROGRESS pdc "checks: deployment IN_PROGRESS exits 1" 1 "${ARGS[@]}"
has "checks: names the rollout state" "$out$err" "IN_PROGRESS"
FAKE_ROLLOUT=FAILED pdc "checks: deployment FAILED exits 1" 1 "${ARGS[@]}"
FAKE_RUNNING=1 pdc "checks: below desired count exits 1" 1 "${ARGS[@]}"
has "checks: names the counts" "$out$err" "1"
FAKE_LOG_EVENTS="$((SINCE_MS + 5000)) ERROR boom" pdc "checks: ERROR line after <since> exits 1" 1 "${ARGS[@]}"
has "checks: quotes the ERROR line" "$out$err" "ERROR boom"
FAKE_LOG_EVENTS="$((SINCE_MS - 5000)) ERROR old" pdc "checks: ERROR line before <since> exits 0" 0 "${ARGS[@]}"
FAKE_ALARMS="${AP}5xx:ALARM" pdc "checks: an alarm in ALARM exits 1" 1 "${ARGS[@]}"
has "checks: names the alarm" "$out$err" "${AP}5xx"
FAKE_ROLLOUT=FAILED FAKE_ALARMS="${AP}5xx:ALARM" pdc "checks: every failed check is named" 1 "${ARGS[@]}"
has "checks: both failures listed (rollout)" "$out$err" "FAILED"
has "checks: both failures listed (alarm)" "$out$err" "${AP}5xx"
for op in describe-services list-tasks describe-tasks filter-log-events describe-alarms; do
  FAKE_FAIL_OP=$op pdc "checks: $op read error exits 2" 2 "${ARGS[@]}"
done
FAKE_AWS_DENIED=1 pdc "checks: denied exits 2" 2 "${ARGS[@]}"
pdc "checks usage: no args" 64
pdc "checks usage: bad digest" 64 "$CL" "$SV" sha256:x "$SINCE" "$LG" "$AP"
pdc "checks usage: bad since" 64 "$CL" "$SV" "$A" yesterday "$LG" "$AP"
pdc "checks usage: empty alarm prefix" 64 "$CL" "$SV" "$A" "$SINCE" "$LG" ""
empty "checks usage: no aws call" "$AWS_LOG"
unset FAKE_TASKS FAKE_LOG_EVENTS FAKE_ALARMS

# ---------------------------------------------------------------- deploy-comment.sh
G() { git -c commit.gpgsign=false -c user.name=t -c user.email=t@example.invalid "$@"; }
S=$T/svc
G init -q -b master "$S"
G -C "$S" commit -q --allow-empty -m "chore: base"
G -C "$S" commit -q --allow-empty -m "Merge pull request #10 from PlantechHubDev/feat-10"
DEPLOYED=$(git -C "$S" rev-parse HEAD)
G -C "$S" checkout -q -b feat-11
G -C "$S" commit -q --allow-empty -m "Merge pull request #99 from inside/a-branch"
G -C "$S" checkout -q master
G -C "$S" merge -q --no-ff -m "Merge pull request #11 from PlantechHubDev/feat-11" feat-11
G -C "$S" commit -q --allow-empty -m "fix: direct commit"
G -C "$S" commit -q --allow-empty -m "Merge pull request #12 from PlantechHubDev/feat-12"
HEAD12=$(git -C "$S" rev-parse HEAD)
RUN=https://github.com/$REPO/actions/runs/77
export SERVICE=$SVC SERVICE_REPO=$S GITHUB_REPOSITORY=$REPO GITHUB_STEP_SUMMARY=$T/summary.md FAKE_COMMIT=$DEPLOYED
: > "$GITHUB_STEP_SUMMARY"
dc() { run "$1" "$2" deploy-comment.sh "${@:3}"; }
dc "comment: exits 0" 0 "$HEAD12" "$A" "$B" "$RUN"
logs "comment: resolves the previous digest's commit" "$AWS_LOG" "ecr describe-images --repository-name $SVC --image-ids imageDigest=$B"
count "comment: on #11 once" "$GH_LOG" "pr comment 11 " 1
count "comment: on #12 once" "$GH_LOG" "pr comment 12 " 1
nologs "comment: none on #10 (already deployed)" "$GH_LOG" "pr comment 10 "
nologs "comment: none on #99 (not on the first-parent history)" "$GH_LOG" "pr comment 99 "
count "comment: two comments in all" "$GH_LOG" "pr comment" 2
logs "comment: on the service repo" "$GH_LOG" "--repo $REPO"
logs "comment: body has the digest" "$GH_LOG" "$A"
logs "comment: body has the previous digest" "$GH_LOG" "$B"
logs "comment: body has the run link" "$GH_LOG" "$RUN"
logs "comment: body says stable" "$GH_LOG" "stable"
logs "comment: step summary repeats it" "$GITHUB_STEP_SUMMARY" "$A"
logs "comment: step summary lists the PRs" "$GITHUB_STEP_SUMMARY" "#12"
FAKE_COMMIT=$HEAD12 dc "comment: re-run (nothing new) exits 0" 0 "$HEAD12" "$A" "$A" "$RUN"
nologs "comment: re-run comments on none" "$GH_LOG" "pr comment"
FAKE_COMMENT_EXIT=1 dc "comment: gh failure exits 1" 1 "$HEAD12" "$A" "$B" "$RUN"
# Previous digest has no sha-<7> tag that resolves: only the merge's own PR is commented on.
FAKE_COMMIT=nope dc "comment: unknown previous commit still exits 0" 0 "$HEAD12" "$A" "$B" "$RUN"
count "comment: unknown previous: only the merge's own PR" "$GH_LOG" "pr comment 12 " 1
count "comment: unknown previous: nothing else" "$GH_LOG" "pr comment" 1
has "comment: unknown previous: warns" "$out$err" "::warning::"
dc "comment usage: no args" 64
dc "comment usage: bad digest" 64 "$HEAD12" sha256:x "$B" "$RUN"
dc "comment usage: bad merge sha" 64 abc "$A" "$B" "$RUN"
SERVICE='' dc "comment usage: SERVICE unset" 64 "$HEAD12" "$A" "$B" "$RUN"
empty "comment usage: no gh call" "$GH_LOG"

exit $status
