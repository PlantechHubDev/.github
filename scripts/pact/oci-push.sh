#!/usr/bin/env bash
# Usage: oci-push.sh [--tag <tag>] <package> <dir> <sha>
# With --tag <tag>, pushes only :<tag> (e.g. pr-7), on any branch.
# On the default branch, pushes every *.json in <dir> to ghcr.io/plantechhubdev/<package> tagged
# `default` and `sha-<first 7 of sha>`. Anywhere else, or with no json files, prints a notice and
# exits 0. Needs oras logged in to ghcr.io (ORAS_REGISTRY_CONFIG, when set, is passed as
# --registry-config); reads GITHUB_REF_NAME and GITHUB_REPOSITORY.
set -euo pipefail
usage="usage: oci-push.sh [--tag <tag>] <package> <dir> <sha>"
tag=""
if [ "${1:-}" = "--tag" ]; then
  [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
  tag=$2; shift 2
  [[ $tag =~ ^pr-[0-9]+$|^[a-z0-9][a-z0-9._-]*$ ]] || { echo "::error::Invalid tag '$tag'"; exit 2; }
fi
[ $# -eq 3 ] || { echo "$usage" >&2; exit 2; }
package=$1 dir=$2 sha=$3
here=$(cd "$(dirname "$0")" && pwd)

if [ -z "$tag" ]; then
  default=$("$here/default-branch.sh")
  if [ "${GITHUB_REF_NAME:-}" != "$default" ]; then
    echo "::notice::Not publishing $package: ${GITHUB_REF_NAME:-<no ref>} is not the default branch ($default)"
    exit 0
  fi
  tags="default,sha-${sha:0:7}"
else
  tags=$tag
fi

shopt -s nullglob
cd "$dir"
files=(*.json)
if [ ${#files[@]} -eq 0 ]; then
  echo "::notice::Not publishing $package: no *.json files in $dir"
  exit 0
fi

args=()
for f in "${files[@]}"; do args+=("$f:application/json"); done
auth=()
[ -z "${ORAS_REGISTRY_CONFIG:-}" ] || auth=(--registry-config "$ORAS_REGISTRY_CONFIG")
oras push ${auth[@]+"${auth[@]}"} "ghcr.io/plantechhubdev/$package:$tags" \
  --annotation "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:?}" \
  "${args[@]}"
