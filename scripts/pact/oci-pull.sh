#!/usr/bin/env bash
# Usage: oci-pull.sh [--pr-tags <days>] <out-dir> <package>...
# Pulls ghcr.io/plantechhubdev/<package>:default into <out-dir>/<package> for each package.
# With --pr-tags <days>, also pulls every pr-<n> tag of each package whose manifest annotation
# org.opencontainers.image.created is under <days> days old into <out-dir>/pr-<n>/<package>, and then
# the default pull goes to <out-dir>/default/<package> (source folders, as results.sh reads them).
# Without --pr-tags the layout is <out-dir>/<package>.
# (tags listed with `oras repo tags`; a package whose tags cannot be listed gets a notice).
# GHCR answers an unpublished package and one without an Actions access grant the same way
# (denied / not found), so both print a notice and are skipped. Any other error fails.
# Needs oras logged in to ghcr.io; when ORAS_REGISTRY_CONFIG is set, it is passed as
# --registry-config so credentials can live in a temporary file. <out-dir> always exists afterwards.
set -uo pipefail
usage="usage: oci-pull.sh [--pr-tags <days>] <out-dir> <package>..."
days=""
if [ "${1:-}" = "--pr-tags" ]; then
  [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
  days=$2; shift 2
  [[ $days =~ ^[0-9]+$ ]] || { echo "::error::--pr-tags needs a whole number of days (got '$days')"; exit 2; }
fi
[ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
out=$1; shift
for package in "$@"; do
  [[ $package =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { echo "::error::Invalid package name '$package' (lower-case letters, digits, dots, dashes, underscores)"; exit 2; }
done
mkdir -p "$out"
auth=()
[ -z "${ORAS_REGISTRY_CONFIG:-}" ] || auth=(--registry-config "$ORAS_REGISTRY_CONFIG")
rc=0
# pull_tag <package> <tag> <dest>: pull one tag; unreadable is a notice, other errors set rc=1.
pull_tag() {
  if err=$(oras pull ${auth[@]+"${auth[@]}"} "ghcr.io/plantechhubdev/$1:$2" -o "$3" 2>&1 </dev/null); then
    echo "Pulled $1:$2 into $3"
  elif grep -qiE 'denied:|: not found|manifest unknown' <<<"$err"; then
    echo "::notice::$1:$2 not readable (not published yet, or no Actions access grant); skipped"
  else
    echo "::error::Pulling $1:$2 failed: $err"
    rc=1
  fi
}
for package in "$@"; do
  if [ -z "$days" ]; then pull_tag "$package" default "$out/$package"; continue; fi
  pull_tag "$package" default "$out/default/$package"
  if ! tags=$(oras repo tags ${auth[@]+"${auth[@]}"} "ghcr.io/plantechhubdev/$package" 2>&1); then
    if grep -qiE 'denied:|: not found|manifest unknown|name unknown' <<<"$tags"; then
      echo "::notice::$package pr tags not listable (not published yet, or no Actions access grant); skipped"
    else
      echo "::error::Listing $package tags failed: $tags"; rc=1
    fi
    continue
  fi
  while read -r tag; do
    if ! manifest=$(oras manifest fetch ${auth[@]+"${auth[@]}"} "ghcr.io/plantechhubdev/$package:$tag" 2>&1 </dev/null); then
      if grep -qiE 'denied:|: not found|manifest unknown' <<<"$manifest"; then
        echo "::notice::$package:$tag manifest not readable; skipped"
      else
        echo "::error::Fetching $package:$tag manifest failed: $manifest"; rc=1
      fi
      continue
    fi
    # age in jq (portable; no GNU/BSD date): created is RFC 3339 UTC, fractional seconds dropped
    if jq -e --argjson d "$days" '.annotations["org.opencontainers.image.created"] // empty
        | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | (now - .) < $d * 86400' <<<"$manifest" >/dev/null 2>&1; then
      pull_tag "$package" "$tag" "$out/$tag/$package"
    else
      echo "Skipping $package:$tag (older than $days days, or no created annotation)"
    fi
  done < <(grep -E '^pr-[0-9]+$' <<<"$tags" || true)
done
exit $rc
