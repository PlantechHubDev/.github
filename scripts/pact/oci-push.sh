#!/usr/bin/env bash
# Usage: oci-push.sh <package> <dir> <sha>
# On the default branch, pushes every *.json in <dir> to ghcr.io/plantechhubdev/<package> tagged
# `default` and `sha-<first 7 of sha>`. Anywhere else, or with no json files, prints a notice and
# exits 0. Needs oras logged in to ghcr.io; reads GITHUB_REF_NAME and GITHUB_REPOSITORY.
set -euo pipefail
[ $# -eq 3 ] || { echo "usage: oci-push.sh <package> <dir> <sha>" >&2; exit 2; }
package=$1 dir=$2 sha=$3
here=$(cd "$(dirname "$0")" && pwd)

default=$("$here/default-branch.sh")
if [ "${GITHUB_REF_NAME:-}" != "$default" ]; then
  echo "::notice::Not publishing $package: ${GITHUB_REF_NAME:-<no ref>} is not the default branch ($default)"
  exit 0
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
oras push "ghcr.io/plantechhubdev/$package:default,sha-${sha:0:7}" \
  --annotation "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:?}" \
  "${args[@]}"
