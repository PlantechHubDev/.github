#!/usr/bin/env bash
# ecs-deploy.sh <cluster> <service>: deploy the image just tagged :master to an ECS service by
# forcing a new deployment (the task definition keeps <service>:master, so new tasks pull the new
# image), then wait for the service to be stable. java-service-release.yml calls it right after
# release-image.sh; the digest, rollout, log and alarm checks are post-deploy-checks.sh's.
#
# Steps: aws ecs update-service --force-new-deployment -> aws ecs wait services-stable (the
# waiter's own timeout, about 10 minutes). The previous digest for the deployment comment comes
# from release-image.sh (what :master named before the retag).
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

aws ecs update-service --cluster "$cluster" --service "$service" --force-new-deployment --output json >/dev/null 2>"$err" \
  || die "cannot force a new deployment of $service: $(head -n 1 "$err")"
echo "ecs-deploy: forced a new deployment of $service; waiting for it to be stable" >&2
aws ecs wait services-stable --cluster "$cluster" --services "$service" 2>"$err" \
  || die "$service did not become stable: $(head -n 1 "$err")"

echo "stable $service"
