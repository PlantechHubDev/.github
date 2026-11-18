#!/usr/bin/env bash
# pth-sim.sh <service> <sha256:digest> <queue-sha>: the merge queue's prod simulation, run on the
# developer's Mac (self-hosted runner, labels self-hosted + pth-test) by pth-sim.yml.
# It runs the full platform-tests suite on the queue image <digest> of <service> (repo and ECR
# name, e.g. orchestration-service) against the images prod is running now (--prod-fleet).
#
# Steps, in order:
#   1. Check the arguments and DEV (the workspace dev dir: engineering-handbook, platform-tests),
#      MG_HEAD_REF (the merge_group head_ref, refs/heads/gh-readonly-queue/...) and
#      GITHUB_REPOSITORY. Then, before SSO, the stack lock or npm, check with gh that the queue
#      entry's branch still exists: a 404 (the queue dropped the entry while the job waited, e.g.
#      for an asleep Mac) is exit 5, any other gh error exit 2.
#   2. Read the digest prod is RUNNING for <service> the way platform-tests --prod-fleet does
#      (ECS service prod-<service>-svc in prod-pth-cluster), and check that <digest> is an image
#      in <service>'s ECR repository. Read-only, through the developer's SSO profile
#      ($PTH_AWS_PROFILE, default pth-admin-prod). An expired session stops here, before npm or
#      the stack lock.
#   3. deployed-sha.sh: running digest -> the commit prod runs.
#   4. pt-ref <service> --release <deployed>..<queue-sha>: the platform-tests commit. More than one
#      paired platform-tests PR in the range ("split the release") is exit 3; any other pt-ref
#      error is exit 2, never a fallback to master.
#   5. The handbook's pt-verify block (engineering-handbook testing.md, <!-- cmd:pt-verify -->),
#      with --prod-fleet and the queue image by digest. Differences from the block, each needed
#      for a non-interactive run: pt-ref's commit comes from step 4 (not --here); a busy pool is
#      announced ("waiting for a pth-test stack") before the blocking take; RESULT is printed by
#      this script after the block's subshell has exited, so it comes after the env:down cleanup
#      and stays the last line of the log; after the lease, `aws sts get-caller-identity`
#      re-checks the SSO session (it may expire during a long wait) and ends the run with exit 4;
#      the block runs in the background so INT/TERM/HUP (job cancel or timeout) are forwarded
#      to it and the library's traps release the lease.
#   6. A markdown summary to $GITHUB_STEP_SUMMARY (service, queue sha, deployed sha,
#      platform-tests commit, result).
#
# Exit: 0 pass; 1 simulation failed (env:up or tests); 2 resolver or setup error (ECS, ECR,
# deployed sha, pt-ref, stack lease, worktree or npm ci); 3 more than one paired platform-tests
# change; 4 AWS SSO expired; 5 queue entry gone (its merge-queue branch no longer exists); 64
# usage. Prints "RESULT <rc>" last.
# Overrides (tests): PT_REF (pt-ref path), PTH_STACK_LIB (pth-stack library path).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CLUSTER=prod-pth-cluster
SSO_ERRORS='Token has expired|refresh failed|SSO session .*(expired|invalid)|sso.*(expired|invalid)|Unable to locate credentials|ExpiredToken|The config profile .* could not be found|Error loading SSO Token'

svc=${1-} digest=${2-} queue=${3-}
deployed="" ptsha=""

# summary <result text>: the step summary; a no-op outside Actions.
summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    echo "### pth-sim: prod simulation"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Service | \`${svc:-?}\` |"
    echo "| Queue image | \`${digest:-?}\` |"
    echo "| Queue commit | \`${queue:-?}\` |"
    echo "| Deployed commit (running in prod) | \`${deployed:-unknown}\` |"
    echo "| platform-tests commit | \`${ptsha:-unknown}\` |"
    echo "| Result | $1 |"
  } >>"$GITHUB_STEP_SUMMARY"
}
# finish <exit> <message>: stop before the run with a plain message, summary and RESULT line.
finish() {
  echo "pth-sim: $2" >&2
  summary "$3"
  echo "RESULT $1"
  exit "$1"
}
usage() { echo "usage: pth-sim.sh <service> <sha256:digest> <queue-sha>" >&2; finish 64 "$1" "usage error"; }

# --- 1. arguments and environment
[ $# -eq 3 ] || usage "expected 3 arguments, got $#"
[[ $svc =~ ^[a-z0-9][a-z0-9-]*-service$ ]] || usage "service must be the repo/ECR name ending in -service (got '$svc')"
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || usage "digest must be sha256:<64 hex> (got '$digest'): the queue image job gave no digest"
[[ $queue =~ ^[0-9a-f]{40}$ ]] || usage "queue sha must be 40 hex (got '$queue')"
[ -n "${DEV:-}" ] || usage "DEV is not set: the runner's environment must name the workspace dev dir"
[[ ${MG_HEAD_REF:-} == refs/heads/?* ]] || usage "MG_HEAD_REF must be the merge_group head_ref refs/heads/<queue branch> (got '${MG_HEAD_REF:-}')"
[[ ${GITHUB_REPOSITORY:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "GITHUB_REPOSITORY must be <owner>/<repo> (got '${GITHUB_REPOSITORY:-}')"
short=${svc%-service}
PT_REF=${PT_REF:-$DEV/engineering-handbook/tools/pt-ref/pt-ref}
PTH_STACK_LIB=${PTH_STACK_LIB:-$HOME/.local/bin/pth-stack}

# Read-only AWS through the developer's SSO profile, as platform-tests lib/aws.ts (awsEnv) does.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
export AWS_PROFILE=${PTH_AWS_PROFILE:-pth-admin-prod} AWS_REGION=us-east-1

err=$(mktemp); trap 'rm -f "$err"' EXIT

# --- 1b. the queue entry still exists. A job that waited for an asleep Mac must not start a
# stale simulation: once the queue drops the entry (it failed, timed out or was removed), its
# branch is deleted. Checked before SSO, the stack lock and npm.
qbranch=${MG_HEAD_REF#refs/heads/}
if ! gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/$qbranch" >/dev/null 2>"$err"; then
  if grep -q 'HTTP 404' "$err"; then
    finish 5 "queue entry gone: $GITHUB_REPOSITORY has no branch $qbranch any more (the merge queue dropped this entry); not starting a stale simulation" "queue entry gone"
  fi
  finish 2 "cannot look up the queue branch $qbranch in $GITHUB_REPOSITORY: $(head -n 1 "$err")" "resolver error"
fi
# awsj <args...>: one read-only aws call, JSON into $J. Called directly (never inside $(...)) so
# that finish exits the script: SSO trouble is exit 4, anything else 2.
awsj() {
  if J=$(aws "$@" --output json 2>"$err"); then return 0; fi
  if grep -Eqi -- "$SSO_ERRORS" "$err"; then
    finish 4 "SSO session expired: run aws sso login --profile $AWS_PROFILE ($(head -n 1 "$err"))" "AWS SSO expired"
  fi
  finish 2 "aws $1 $2 failed: $(head -n 1 "$err")" "resolver error"
}

# --- 2. what prod runs, and the queue image
ecs=prod-$svc-svc
awsj ecs list-tasks --cluster "$CLUSTER" --service-name "$ecs" --desired-status RUNNING
arns=$(jq -r '.taskArns[]?' <<<"$J")
[ -n "$arns" ] || finish 2 "no RUNNING task for $ecs" "resolver error"
# shellcheck disable=SC2086  # one argument per task ARN
awsj ecs describe-tasks --cluster "$CLUSTER" --tasks $arns
running=$(jq -r --arg suf "/$svc" '.tasks[] | select(.lastStatus == "RUNNING") | .containers[]?
      | select((.image // "") | sub("[@:].*$"; "") | endswith($suf)) | .imageDigest // ""' <<<"$J" | sort -u)
case $(printf '%s' "$running" | grep -c .) in
  0) finish 2 "no running $svc container with an image digest in $ecs" "resolver error" ;;
  1) ;;
  *) finish 2 "$ecs runs different digests ($(printf '%s' "$running" | tr '\n' ' ')): deployment in progress? re-run when it settles" "resolver error" ;;
esac
[[ $running =~ ^sha256:[0-9a-f]{64}$ ]] || finish 2 "$ecs reports a malformed digest '$running'" "resolver error"

aws ecr describe-images --repository-name "$svc" --image-ids "imageDigest=$digest" --output json >/dev/null 2>"$err" \
  || { grep -Eqi -- "$SSO_ERRORS" "$err" && finish 4 "SSO session expired: run aws sso login --profile $AWS_PROFILE" "AWS SSO expired"
       finish 2 "queue digest $digest is not an image in $svc's ECR repository: $(head -n 1 "$err")" "resolver error"; }
awsj ecr describe-repositories --repository-names "$svc"
uri=$(jq -r '.repositories[0].repositoryUri // empty' <<<"$J")
[[ $uri =~ ^[a-z0-9.-]+/[a-z0-9._-]+$ ]] || finish 2 "ECR repository URI for $svc is missing or malformed (got '$uri')" "resolver error"

# --- 3. the commit prod runs
deployed=$(bash "$HERE/deployed-sha.sh" "$svc" "$running"); rc=$?
case $rc in
  0) ;;
  4) finish 4 "SSO session expired: run aws sso login --profile $AWS_PROFILE" "AWS SSO expired" ;;
  *) finish 2 "cannot resolve the commit of the running digest $running (deployed-sha.sh exit $rc)" "resolver error" ;;
esac

# --- 4. the platform-tests commit for the release range
ptref=$("$PT_REF" "$svc" --release "$deployed..$queue" 2>"$err"); rc=$?
if [ $rc -ne 0 ]; then
  if [ $rc -eq 2 ] && grep -q 'split the release' "$err"; then
    finish 3 "more than one paired platform-tests change between prod and the queue commit; ship them in separate queue entries: $(cat "$err")" "more than one paired platform-tests change"
  fi
  finish 2 "pt-ref failed (exit $rc), no fallback to master: $(cat "$err")" "resolver error"
fi
ptsha=${ptref%% *}
[[ $ptsha =~ ^[0-9a-f]{40}$ ]] || finish 2 "pt-ref gave no platform-tests commit (got '$ptref')" "resolver error"
echo "pth-sim: $svc queue $queue (image $digest) vs prod $deployed; platform-tests $ptref"

# --- 5. the run. Mirrors the handbook pt-verify block (engineering-handbook testing.md,
# <!-- cmd:pt-verify -->); see the header for the differences.
state=$(mktemp -d)
(
# shellcheck disable=SC1090  # the pth-stack library, path chosen at run time
. "$PTH_STACK_LIB" || exit 1
up=0
# shellcheck disable=SC2329  # called by the library's exit cleanup
pth_stack_down() { [ "$up" = 1 ] && pth_stack_phase env_down && npm run env:down; }
export PTH_PT_REF="$ptref"
pth_stack_try; t=$?
if [ "$t" = 75 ]; then echo "pth-sim: waiting for a pth-test stack (all busy); the job's timeout bounds the wait"; pth_stack_take
elif [ "$t" != 0 ]; then exit "$t"; fi
# The SSO session may have expired while the run waited for a stack: re-check before env:up.
if ! aws sts get-caller-identity --output json >/dev/null 2>"$err"; then
  if grep -Eqi -- "$SSO_ERRORS" "$err"; then : > "$state/sso"; exit 4; fi
  echo "pth-sim: aws sts get-caller-identity failed: $(head -n 1 "$err")" >&2; exit 2
fi
pth_stack_phase prepare
# shellcheck disable=SC2155  # verbatim from the block
export DOCKER_CONFIG="$(mktemp -d)" DOCKER_HOST="unix://$HOME/.docker/run/docker.sock"
echo '{}' > "$DOCKER_CONFIG/config.json"; ln -s "$HOME/.docker/cli-plugins" "$DOCKER_CONFIG/cli-plugins"
PT="${DEV}/platform-tests/.worktrees/verify-${PTH_STACK:-1}"; export PTH_DEMO_DIR="${DEV}/demo"
git -C "${DEV}/platform-tests" fetch -q origin && { [ -e "$PT/.git" ] || git -C "${DEV}/platform-tests" worktree add -q --detach "$PT" "$ptsha"; } &&
  git -C "$PT" checkout -q --detach "$ptsha" && cd "$PT" && npm ci --no-audit --no-fund || exit 1
: > "$state/ran"
pth_stack_phase env_up; up=1; npm run env:up -- --portal --prod-fleet --image "${short}=${uri}@${digest}" && { pth_stack_phase tests; npm test -- --allow-non-master; }; rc=$?
pth_stack_exit $rc
) &
# A job cancel or timeout signals this script: pass it on so the library's traps release the
# lease. bash runs a trapped signal only once its foreground child returns, so the subshell's
# direct children (npm) get the TERM too. The subshell is signalled first, so its trap is already
# pending when the child dies and runs before the block's normal exit path.
pid=$!
trap 'kill -TERM "$pid" 2>/dev/null; pkill -TERM -P "$pid" 2>/dev/null; wait "$pid"' INT TERM HUP
wait "$pid"; rc=$?
trap - INT TERM HUP
if [ -e "$state/sso" ]; then
  rm -rf "$state"
  finish 4 "SSO session expired: run aws sso login --profile $AWS_PROFILE (it expired while the run waited for a stack)" "AWS SSO expired"
fi
if [ ! -e "$state/ran" ]; then
  rm -rf "$state"
  finish 2 "the run did not start (pth-test stack refused or never free, or the platform-tests worktree / npm ci failed; exit $rc)" "setup error (exit $rc)"
fi
rm -rf "$state"
# --- 6. summary, then RESULT last
if [ $rc -eq 0 ]; then summary "pass (0)"; else summary "fail ($rc)"; fi
echo "RESULT $rc"
[ $rc -eq 0 ] || exit 1
