#!/usr/bin/env bash
# ecs-deploy.sh <cluster> <service>: deploy the image just tagged :master to an ECS service by
# forcing a new deployment (the task definition keeps <service>:master, so new tasks pull the new
# image), then wait for the service to be stable. java-service-release.yml calls it right after
# release-image.sh; the digest, rollout, log and alarm checks are post-deploy-checks.sh's.
#
# Steps: read the digest the service runs now (the previous digest: the container whose image
# ends in :master, else the first container, of the first running task) -> aws ecs
# update-service --force-new-deployment -> aws ecs wait services-stable (the waiter's own
# timeout, about 10 minutes). Writes previous-digest=<digest> to GITHUB_OUTPUT when set (empty
# when no task was running), for the deployment comment.
#
# AWS: the caller's credentials and region (the release workflow: the OIDC deploy role, us-east-1).
# Prints "stable <service>" as the last stdout line on success.
# Exit: 0 deployed and stable; 1 aws failure, or not stable in time; 64 usage.
set -uo pipefail
usage() { echo "ecs-deploy: $1" >&2; echo "usage: ecs-deploy.sh <cluster> <service>" >&2; exit 64; }
[ $# -eq 2 ] || usage "expected 2 arguments, got $#"
cluster=$1 service=$2
NAME_RE='^[A-Za-z0-9][A-Za-z0-9_./:-]*$'
[[ $cluster =~ $NAME_RE ]] || usage "bad cluster '$cluster'"
[[ $service =~ $NAME_RE ]] || usage "bad service '$service'"

err=$(mktemp); trap 'rm -f "$err"' EXIT
die() { echo "::error::ecs-deploy: $*" >&2; exit 1; }

# running_tasks: describe-tasks JSON of the service's running tasks ({"tasks":[]} when none).
running_tasks() {
  local arns a ids
  arns=$(aws ecs list-tasks --cluster "$cluster" --service-name "$service" --desired-status RUNNING --output json 2>"$err") \
    || { echo "cannot list the tasks of $service: $(head -n 1 "$err")" >&2; return 1; }
  ids=()
  while IFS= read -r a; do [ -z "$a" ] || ids+=("$a"); done < <(jq -r '.taskArns[]?' <<<"$arns")
  if [ "${#ids[@]}" -eq 0 ]; then echo '{"tasks":[]}'; return 0; fi
  aws ecs describe-tasks --cluster "$cluster" --tasks "${ids[@]}" --output json 2>"$err" \
    || { echo "cannot describe the tasks of $service: $(head -n 1 "$err")" >&2; return 1; }
}

before=$(running_tasks) || die "cannot read what $service runs now"
previous=$(jq -r '[.tasks[0].containers[]? | select(.image | endswith(":master"))][0].imageDigest
  // .tasks[0].containers[0].imageDigest // empty' <<<"$before" 2>/dev/null)
echo "ecs-deploy: $service runs ${previous:-nothing} now" >&2
[ -z "${GITHUB_OUTPUT:-}" ] || echo "previous-digest=$previous" >> "$GITHUB_OUTPUT"

aws ecs update-service --cluster "$cluster" --service "$service" --force-new-deployment --output json >/dev/null 2>"$err" \
  || die "cannot force a new deployment of $service: $(head -n 1 "$err")"
echo "ecs-deploy: forced a new deployment of $service; waiting for it to be stable" >&2
aws ecs wait services-stable --cluster "$cluster" --services "$service" 2>"$err" \
  || die "$service did not become stable: $(head -n 1 "$err")"

echo "stable $service"
