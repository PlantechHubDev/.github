#!/usr/bin/env bash
# Usage: oci-pull.sh <out-dir> <package>...
# Pulls ghcr.io/plantechhubdev/<package>:default into <out-dir>/<package> for each package.
# GHCR answers an unpublished package and one without an Actions access grant the same way
# (denied / not found), so both print a notice and are skipped. Any other error fails.
# Needs oras logged in to ghcr.io.
set -uo pipefail
[ $# -ge 2 ] || { echo "usage: oci-pull.sh <out-dir> <package>..." >&2; exit 2; }
out=$1; shift
rc=0
for package in "$@"; do
  if err=$(oras pull "ghcr.io/plantechhubdev/$package:default" -o "$out/$package" 2>&1); then
    echo "Pulled $package:default into $out/$package"
  elif grep -qiE 'denied|not found|manifest unknown' <<<"$err"; then
    echo "::notice::$package:default not readable (not published yet, or no Actions access grant); skipped"
  else
    echo "::error::Pulling $package:default failed: $err"
    rc=1
  fi
done
exit $rc
