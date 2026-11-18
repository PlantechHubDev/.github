#!/usr/bin/env bash
# ecr-existing-digest.sh <repository> <tag>: print the digest of <repository>:<tag> in ECR.
# Prints nothing and exits 0 when the tag does not exist (build it). Any other aws
# failure, or an unreadable answer, exits 1, so a permissions problem is never taken as "absent".
set -uo pipefail
repo=${1:?repository} tag=${2:?tag}
HERE=$(cd "$(dirname "$0")" && pwd)
err=$(mktemp); trap 'rm -f "$err"' EXIT
if json=$(aws ecr describe-images --repository-name "$repo" --image-ids "imageTag=$tag" --output json 2>"$err"); then
  printf '%s' "$json" | bash "$HERE/image-digest.sh" --existing
elif grep -q 'ImageNotFoundException' "$err"; then
  exit 0
else
  cat "$err" >&2
  exit 1
fi
