#!/usr/bin/env bash
# release-image.sh <service> <merge-sha> <ecs-cluster> <ecs-service>: guard, then tag the image to
# deploy, <service>:sha-<first 7 of merge-sha> (the image the merge queue built and simulated), as
# master. java-service-release.yml deploys by moving :master and forcing a new ECS deployment, so
# the running prod service must actually deploy :master.
#
# - Guard (read-only): aws ecs describe-services gives the service's task definition, and
#   describe-task-definition its containers. Every container whose image is in the service's ECR
#   repository (<anything>/<service> followed by :<tag>, @<digest> or nothing) MUST reference
#   <anything>/<service>:master, and there must be at least one. A digest-pinned image, any other
#   tag (or none), or no container of the repository exits 3 with an ::error:: naming the image:
#   nothing is written to AWS and nothing in prod changes.
# - Previous: the digest :master names before the retag (scripts/ecr-existing-digest.sh), for the
#   deployment comment's text only ("replaces <digest>"). Empty when there is no :master yet, or when
#   :master already names the new image (a re-run: the previous one is then unknown).
# - Retag: sha-<7> is tagged master with scripts/ecr-retag.sh (same manifest, no rebuild). A
#   re-run on the same merge (master already names that image) exits 0.
#
# Prints the digest as the last stdout line, and writes digest=<digest> and
# previous-digest=<digest or empty> to GITHUB_OUTPUT when set.
# AWS: the caller's credentials and region (the release workflow: the OIDC deploy role, us-east-1).
# Exit: 0 retagged (digest printed); 1 aws failure (no write when the guard's reads fail);
# 2 sha-<7> not in ECR (never rebuilt); 3 the guard refused (no AWS write); 64 usage.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
usage() { echo "release-image: $1" >&2; echo "usage: release-image.sh <service> <merge-sha> <ecs-cluster> <ecs-service>" >&2; exit 64; }
[ $# -eq 4 ] || usage "expected 4 arguments, got $#"
svc=$1 merge=$2 cluster=$3 service=$4
NAME_RE='^[A-Za-z0-9][A-Za-z0-9_./:-]*$'
[[ $svc =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage "bad service name '$svc'"
[[ $merge =~ ^[0-9a-f]{40}$ ]] || usage "merge-sha must be 40 hex (got '$merge')"
[[ $cluster =~ $NAME_RE ]] || usage "bad cluster '$cluster'"
[[ $service =~ $NAME_RE ]] || usage "bad ECS service '$service'"
from=sha-${merge:0:7}
to=master
err=$(mktemp); trap 'rm -f "$err"' EXIT

# --- Guard: what the running service deploys.
json=$(aws ecs describe-services --cluster "$cluster" --services "$service" --output json 2>"$err") \
  || { echo "::error::release-image: cannot read the ECS service $service: $(head -n 1 "$err")" >&2; exit 1; }
td=$(jq -r '.services[0].taskDefinition // empty' <<<"$json" 2>/dev/null)
[ -n "$td" ] || { echo "::error::release-image: the ECS service $service in $cluster was not found or has no task definition" >&2; exit 1; }
json=$(aws ecs describe-task-definition --task-definition "$td" --output json 2>"$err") \
  || { echo "::error::release-image: cannot read the task definition of $service: $(head -n 1 "$err")" >&2; exit 1; }
images=$(jq -r '.taskDefinition.containerDefinitions[]?.image // empty' <<<"$json" 2>/dev/null)
mine="" bad=""
while IFS= read -r img; do
  [ -n "$img" ] || continue
  # In the service's repository: .../<svc> then :tag, @digest or the end.
  [[ $img =~ /$svc(:[^/]*|@.*)?$ ]] || continue
  mine="$mine $img"
  [[ $img =~ ^.+/$svc:$to$ ]] || bad="$bad $img"
done <<<"$images"
if [ -z "$mine" ]; then
  echo "::error::$svc is not released: no container of the ECS service $service runs the $svc repository (task definition images:$(tr '\n' ' ' <<<" $images")). Nothing was retagged and nothing in prod changed."
  exit 3
fi
if [ -n "$bad" ]; then
  echo "::error::$svc is not released: the ECS service $service must deploy <registry>/$svc:$to, so that the forced deployment runs the merged image, and it runs:$bad. Nothing was retagged and nothing in prod changed."
  exit 3
fi

# --- What :master names now (read-only).
previous=$(bash "$HERE/ecr-existing-digest.sh" "$svc" "$to") \
  || { echo "::error::release-image: cannot read $svc:$to in ECR; nothing was retagged" >&2; exit 1; }

# --- Retag.
digest=$(bash "$HERE/ecr-retag.sh" "$svc" "$from" "$to"); rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
[ "$previous" != "$digest" ] || previous=""
[ -z "${GITHUB_OUTPUT:-}" ] || { echo "digest=$digest"; echo "previous-digest=$previous"; } >> "$GITHUB_OUTPUT"
echo "$digest"
