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
# Checks (all run; each failure is named):
#   digest      every running task has a container running <digest> (and at least one task runs)
#   deployment  the PRIMARY deployment's rolloutState is COMPLETED, and the service's
#               runningCount equals its desiredCount
#   logs        no log event matching ERROR in <log-group> at or after <since-iso>
#   alarms      no CloudWatch alarm whose name starts with <alarm-prefix> is in state ALARM
#
# AWS: read-only (ecs describe-services, list-tasks, describe-tasks; logs filter-log-events;
# cloudwatch describe-alarms) with the caller's credentials and region.
# Output: one "PASS <check>" or "FAIL <check>: <why>" line per check on stdout (and an ::error::
# per failure on stderr).
# Exit: 0 all pass; 1 a check failed; 2 an AWS read failed (the checks are then unknown); 64 usage.
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

err=$(mktemp); trap 'rm -f "$err"' EXIT
failed=0
readerr() { echo "::error::post-deploy-checks: cannot $1: $(head -n 1 "$err")" >&2; exit 2; }
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; echo "::error::post-deploy-checks: $1: $2" >&2; failed=1; }

# --- digest
arns=$(aws ecs list-tasks --cluster "$cluster" --service-name "$service" --desired-status RUNNING --output json 2>"$err") \
  || readerr "list the tasks of $service"
ids=()
while IFS= read -r a; do [ -z "$a" ] || ids+=("$a"); done < <(jq -r '.taskArns[]?' <<<"$arns")
if [ "${#ids[@]}" -eq 0 ]; then
  bad digest "no task of $service is running"
else
  tasks=$(aws ecs describe-tasks --cluster "$cluster" --tasks "${ids[@]}" --output json 2>"$err") \
    || readerr "describe the tasks of $service"
  wrong=$(jq -r --arg d "$digest" '.tasks[] | select([.containers[]?.imageDigest] | index($d) | not)
    | "\(.taskArn | split("/") | last) runs \([.containers[]?.imageDigest] | join(","))"' <<<"$tasks")
  if [ -n "$wrong" ]; then bad digest "not every task runs $digest: $(paste -sd';' - <<<"$wrong")"
  else ok "digest (${#ids[@]} tasks run $digest)"; fi
fi

# --- deployment
svc=$(aws ecs describe-services --cluster "$cluster" --services "$service" --output json 2>"$err") \
  || readerr "describe $service"
jq -e '.services[0]' <<<"$svc" >/dev/null 2>&1 || { echo "::error::post-deploy-checks: $service not found in $cluster" >&2; exit 2; }
rollout=$(jq -r '[.services[0].deployments[]? | select(.status == "PRIMARY")][0].rolloutState // "none"' <<<"$svc")
running=$(jq -r '.services[0].runningCount // 0' <<<"$svc") desired=$(jq -r '.services[0].desiredCount // 0' <<<"$svc")
if [ "$rollout" != COMPLETED ]; then bad deployment "the primary deployment is $rollout, not COMPLETED"
elif [ "$running" != "$desired" ]; then bad deployment "$running of $desired desired tasks running"
else ok "deployment COMPLETED ($running of $desired tasks)"; fi

# --- logs
ev=$(aws logs filter-log-events --log-group-name "$group" --start-time "$since_ms" --filter-pattern ERROR --output json 2>"$err") \
  || readerr "read the log group $group"
errors=$(jq -r --argjson s "$since_ms" '[.events[]? | select(.timestamp >= $s)] | .[:5][] | .message' <<<"$ev")
n=$(jq --argjson s "$since_ms" '[.events[]? | select(.timestamp >= $s)] | length' <<<"$ev")
if [ "$n" -gt 0 ]; then bad logs "$n ERROR line(s) in $group since $since, e.g.: $(head -n 1 <<<"$errors" | cut -c1-300)"
else ok "logs (no ERROR line in $group since $since)"; fi

# --- alarms
al=$(aws cloudwatch describe-alarms --alarm-name-prefix "$prefix" --state-value ALARM --alarm-types MetricAlarm CompositeAlarm --output json 2>"$err") \
  || readerr "read the alarms $prefix*"
alarming=$(jq -r '[.MetricAlarms[]?, .CompositeAlarms[]? | select(.StateValue == "ALARM") | .AlarmName] | join(", ")' <<<"$al")
if [ -n "$alarming" ]; then bad alarms "in ALARM: $alarming"
else ok "alarms (none of $prefix* in ALARM)"; fi

exit "$failed"
