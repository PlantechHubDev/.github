#!/usr/bin/env bash
# ecs-deploy.sh <cluster> <service> <sha256:digest>: deploy the image just tagged :master to an
# ECS service by forcing a new deployment (the task definition keeps <service>:master, so new
# tasks pull the new image), then wait for the service to be stable and check that every
# running task runs <digest>. java-service-release.yml calls it right after release-image.sh.
#
# Steps: read the digest the service runs now (the previous digest: the container whose image
# ends in :master, else the first container, of the first running task) -> aws ecs
# update-service --force-new-deployment -> aws ecs wait services-stable (the waiter's own
# timeout, about 10 minutes) -> every running task must have a container running <digest>.
# Writes previous-digest=<digest> to GITHUB_OUTPUT when set (empty when no task was running).
#
# AWS: the caller's credentials and region (the release workflow: the OIDC deploy role, us-east-1).
# Prints "deployed <digest>" as the last stdout line on success.
# Exit: 0 deployed; 1 aws failure or not stable in time; 4 a running task's digest differs (or
# no task runs); 64 usage.
set -uo pipefail
usage() { echo "ecs-deploy: $1" >&2; echo "usage: ecs-deploy.sh <cluster> <service> <sha256:digest>" >&2; exit 64; }
[ $# -eq 3 ] || usage "expected 3 arguments, got $#"
cluster=$1 service=$2 digest=$3
NAME_RE='^[A-Za-z0-9][A-Za-z0-9_./:-]*$'
[[ $cluster =~ $NAME_RE ]] || usage "bad cluster '$cluster'"
[[ $service =~ $NAME_RE ]] || usage "bad service '$service'"
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || usage "digest must be sha256:<64 hex> (got '$digest')"

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

after=$(running_tasks) || die "cannot read what $service runs after the deployment"
[ "$(jq '.tasks | length' <<<"$after")" -gt 0 ] || { echo "::error::ecs-deploy: no task of $service is running after the deployment" >&2; exit 4; }
wrong=$(jq -r --arg d "$digest" '.tasks[] | select([.containers[]?.imageDigest] | index($d) | not)
  | "\(.taskArn | split("/") | last) runs \([.containers[]?.imageDigest] | join(","))"' <<<"$after")
if [ -n "$wrong" ]; then
  echo "::error::ecs-deploy: $service is stable but not every task runs $digest: $(paste -sd';' - <<<"$wrong")" >&2
  exit 4
fi
echo "deployed $digest"
