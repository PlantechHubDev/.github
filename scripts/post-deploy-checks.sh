#!/usr/bin/env bash
# post-deploy-checks.sh <cluster> <service> <sha256:digest> <since-iso> <log-group> <alarm-prefix>
#
# Read-only checks that a deployment of an ECS service is healthy (pth-context platform-ops
# decision 0124). Self-contained, so any deploy workflow can call it: java-service-release.yml
# runs it after ecs-deploy.sh, and the app-owned ecs-deploy.yml uses it too. Arguments:
#   <cluster> <service>  the ECS cluster and service (names, from the caller's variables)
#   <digest>             sha256:<64 hex>, the image that should be running
#   <since-iso>          when the deployment started, UTC, YYYY-MM-DDTHH:MM:SSZ
#   <log-group>          the service's CloudWatch log group
#   <alarm-prefix>       the name prefix of the service's CloudWatch alarms
#
# The service's containers are those of the running tasks' task definition that log to
# <log-group> with the awslogs driver; each MUST set awslogs-stream-prefix, or the script exits 2
# (it never falls back to scanning the whole group, where tasks of the old deployment also log).
#
# Checks (all run; each failure is named):
#   digest      every running task's service containers run <digest>, or one of the child
#               manifests of <digest> when it is an image index (ECS can record the platform
#               manifest of a multi-arch image). The index is read only on a mismatch, with
#               aws ecr batch-get-image in the repository of the service container's image. At
#               least one task must run.
#   deployment  the PRIMARY deployment's rolloutState is COMPLETED, and the service's
#               runningCount equals its desiredCount
#   logs        no log event matching ERROR at or after <since-iso> in the log streams of the
#               PRIMARY deployment's tasks (startedBy = the deployment id), named by the awslogs
#               convention <awslogs-stream-prefix>/<container name>/<task id>
#   alarms      no CloudWatch alarm whose name starts with <alarm-prefix> is in state ALARM
#
# AWS: read-only (ecs describe-services, list-tasks, describe-tasks, describe-task-definition;
# ecr batch-get-image; logs filter-log-events; cloudwatch describe-alarms) with the caller's
# credentials and region.
# Output: one "PASS <check>" or "FAIL <check>: <why>" line per check on stdout (and an ::error::
# per failure on stderr).
# Exit: 0 all pass; 1 a check failed; 2 an AWS read failed or the log configuration is missing
# (the checks are then unknown); 64 usage.
set -uo pipefail
usage() {
  echo "post-deploy-checks: $1" >&2
  echo "usage: post-deploy-checks.sh <cluster> <service> <sha256:digest> <since-iso> <log-group> <alarm-prefix>" >&2
  exit 64
}
[ $# -eq 6 ] || usage "expected 6 arguments, got $#"
cluster=$1 service=$2 digest=$3 since=$4 group=$5 prefix=$6
NAME_RE='^[A-Za-z0-9][A-Za-z0-9_./:-]*$'
[[ $cluster =~ $NAME_RE ]] || usage "bad cluster '$cluster'"
[[ $service =~ $NAME_RE ]] || usage "bad service '$service'"
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || usage "digest must be sha256:<64 hex> (got '$digest')"
[[ $since =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || usage "since must be UTC YYYY-MM-DDTHH:MM:SSZ (got '$since')"
[[ $group =~ ^[A-Za-z0-9_./#-]+$ ]] || usage "bad log group '$group'"
[ -n "$prefix" ] && [[ $prefix != *[[:space:]]* ]] || usage "alarm-prefix must be non-empty, with no spaces (got '$prefix')"
# GNU date (runners), else BSD date (macOS).
secs=$(date -u -d "$since" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$since" +%s 2>/dev/null) \
  || usage "cannot read the time '$since'"
since_ms=$((secs * 1000))
TYPES=(application/vnd.oci.image.index.v1+json application/vnd.docker.distribution.manifest.list.v2+json
       application/vnd.oci.image.manifest.v1+json application/vnd.docker.distribution.manifest.v2+json)

err=$(mktemp); trap 'rm -f "$err"' EXIT
failed=0
readerr() { echo "::error::post-deploy-checks: cannot $1: $(head -n 1 "$err")" >&2; exit 2; }
unknown() { echo "::error::post-deploy-checks: $1" >&2; exit 2; }
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; echo "::error::post-deploy-checks: $1: $2" >&2; failed=1; }

# --- Reads.
svc=$(aws ecs describe-services --cluster "$cluster" --services "$service" --output json 2>"$err") \
  || readerr "describe $service"
jq -e '.services[0]' <<<"$svc" >/dev/null 2>&1 || unknown "$service not found in $cluster"
primary=$(jq -c '[.services[0].deployments[]? | select(.status == "PRIMARY")][0] // {}' <<<"$svc")
arns=$(aws ecs list-tasks --cluster "$cluster" --service-name "$service" --desired-status RUNNING --output json 2>"$err") \
  || readerr "list the tasks of $service"
ids=()
while IFS= read -r a; do [ -z "$a" ] || ids+=("$a"); done < <(jq -r '.taskArns[]?' <<<"$arns")
tasks='{"tasks":[]}'
if [ "${#ids[@]}" -gt 0 ]; then
  tasks=$(aws ecs describe-tasks --cluster "$cluster" --tasks "${ids[@]}" --output json 2>"$err") \
    || readerr "describe the tasks of $service"
fi
td=$(jq -r '.taskDefinition // empty' <<<"$primary")
[ -n "$td" ] || td=$(jq -r '.services[0].taskDefinition // empty' <<<"$svc")
[ -n "$td" ] || unknown "$service has no task definition"
tdj=$(aws ecs describe-task-definition --task-definition "$td" --output json 2>"$err") \
  || readerr "read the task definition $td"
# The service's containers: "<name> <stream prefix> <image>" for each container logging to <group>.
mine=$(jq -r --arg g "$group" '.taskDefinition.containerDefinitions[]?
  | select(.logConfiguration.logDriver == "awslogs" and .logConfiguration.options["awslogs-group"] == $g)
  | "\(.name) \(.logConfiguration.options["awslogs-stream-prefix"] // "-") \(.image)"' <<<"$tdj")
[ -n "$mine" ] || unknown "no container of $td logs to $group with the awslogs driver (logConfiguration missing): the ERROR scan needs the new tasks' awslogs streams and never scans the whole group"
noprefix=$(awk '$2 == "-" { print $1 }' <<<"$mine")
[ -z "$noprefix" ] || unknown "container(s) $(paste -sd, - <<<"$noprefix") of $td set no awslogs-stream-prefix, so the new tasks' log streams cannot be named; the whole group is never scanned"
names=$(awk '{ print $1 }' <<<"$mine" | jq -R . | jq -s -c .)

# --- digest
# wrong_tasks <allowed JSON array>: "<task id> runs <digests>" for each task whose service
# containers do not all run an allowed digest.
wrong_tasks() {
  jq -r --argjson ok "$1" --argjson n "$names" '.tasks[]
    | [.containers[]? | select(.name as $c | $n | index($c)) | .imageDigest] as $ds
    | select(($ds | length) == 0 or any($ds[]; . as $d | $ok | index($d) | not))
    | "\(.taskArn | split("/") | last) runs \($ds | join(",") | if . == "" then "no service container" else . end)"' <<<"$tasks"
}
if [ "${#ids[@]}" -eq 0 ]; then
  bad digest "no task of $service is running"
else
  allowed=$(jq -n -c --arg d "$digest" '[$d]')
  wrong=$(wrong_tasks "$allowed")
  if [ -n "$wrong" ]; then
    # Maybe a multi-arch index: ECS may run one of its child manifests.
    img=$(awk 'NR == 1 { print $3 }' <<<"$mine")
    repo=${img%@*}; repo=${repo#*/}; [[ ${repo##*/} != *:* ]] || repo=${repo%:*}
    idx=$(aws ecr batch-get-image --repository-name "$repo" --image-ids "imageDigest=$digest" \
      --accepted-media-types "${TYPES[@]}" --output json 2>"$err") || readerr "read the image $repo@$digest"
    manifest=$(jq -r '.images[0].imageManifest // empty' <<<"$idx" 2>/dev/null)
    [ -n "$manifest" ] || unknown "$repo@$digest is not in ECR, so its child manifests cannot be read"
    allowed=$(jq -c --arg d "$digest" '[$d] + [.manifests[]?.digest]' <<<"$manifest" 2>/dev/null) \
      || unknown "cannot read the manifest of $repo@$digest"
    wrong=$(wrong_tasks "$allowed")
  fi
  if [ -n "$wrong" ]; then bad digest "not every task runs $digest (or a child manifest of it): $(paste -sd';' - <<<"$wrong")"
  else ok "digest (${#ids[@]} tasks run $digest)"; fi
fi

# --- deployment
rollout=$(jq -r '.rolloutState // "none"' <<<"$primary")
running=$(jq -r '.services[0].runningCount // 0' <<<"$svc") desired=$(jq -r '.services[0].desiredCount // 0' <<<"$svc")
if [ "$rollout" != COMPLETED ]; then bad deployment "the primary deployment is $rollout, not COMPLETED"
elif [ "$running" != "$desired" ]; then bad deployment "$running of $desired desired tasks running"
else ok "deployment COMPLETED ($running of $desired tasks)"; fi

# --- logs: only the PRIMARY deployment's tasks' streams.
pid=$(jq -r '.id // empty' <<<"$primary")
streams=()
while IFS= read -r s; do [ -z "$s" ] || streams+=("$s"); done < <(
  jq -r --arg p "$pid" '.tasks[] | select(.startedBy == $p) | .taskArn | split("/") | last' <<<"$tasks" |
  while IFS= read -r t; do awk -v t="$t" '{ print $2 "/" $1 "/" t }' <<<"$mine"; done)
if [ "${#streams[@]}" -eq 0 ]; then
  bad logs "no task of the primary deployment ${pid:-?} is running, so there is no log stream to check"
else
  n=0 first=""
  for ((i = 0; i < ${#streams[@]}; i += 100)); do
    ev=$(aws logs filter-log-events --log-group-name "$group" --start-time "$since_ms" --filter-pattern ERROR \
      --log-stream-names "${streams[@]:i:100}" --output json 2>"$err") || readerr "read the log group $group"
    k=$(jq --argjson s "$since_ms" '[.events[]? | select(.timestamp >= $s)] | length' <<<"$ev")
    [ -n "$first" ] || first=$(jq -r --argjson s "$since_ms" '[.events[]? | select(.timestamp >= $s)][0].message // empty' <<<"$ev")
    n=$((n + k))
  done
  if [ "$n" -gt 0 ]; then bad logs "$n ERROR line(s) in the new tasks' streams of $group since $since, e.g.: $(head -n 1 <<<"$first" | cut -c1-300)"
  else ok "logs (no ERROR line in ${#streams[@]} new task stream(s) of $group since $since)"; fi
fi

# --- alarms
al=$(aws cloudwatch describe-alarms --alarm-name-prefix "$prefix" --state-value ALARM --alarm-types MetricAlarm CompositeAlarm --output json 2>"$err") \
  || readerr "read the alarms $prefix*"
alarming=$(jq -r '[.MetricAlarms[]?, .CompositeAlarms[]? | select(.StateValue == "ALARM") | .AlarmName] | join(", ")' <<<"$al")
if [ -n "$alarming" ]; then bad alarms "in ALARM: $alarming"
else ok "alarms (none of $prefix* in ALARM)"; fi

exit "$failed"
