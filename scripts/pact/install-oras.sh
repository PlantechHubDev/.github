#!/usr/bin/env bash
# Installs the pinned oras release (linux amd64) into $RUNNER_TEMP/bin after checking its
# sha256, and adds that directory to $GITHUB_PATH. The pin is bumped here, in one place.
set -euo pipefail
version=1.3.6
file=oras_${version}_linux_amd64.tar.gz
sha256=66fb0ad7206f3f6fa77ed5b552049d364ccf4b50b1684554f731f76302b52ca0

bin=${RUNNER_TEMP:?}/bin
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
curl -fsSL -o "$tmp/$file" "https://github.com/oras-project/oras/releases/download/v${version}/${file}"
echo "$sha256  $tmp/$file" | sha256sum -c -
mkdir -p "$bin"
tar -xzf "$tmp/$file" -C "$bin" oras
echo "$bin" >> "${GITHUB_PATH:?}"
