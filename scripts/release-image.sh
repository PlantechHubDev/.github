#!/usr/bin/env bash
# release-image.sh <service> <merge-sha> < pins: guard, then tag the image to deploy,
# <service>:sha-<first 7 of merge-sha> (the image the merge queue built and simulated), as master.
# stdin is the service's prod units on the infrastructure repo's master, one "<path> <pin>" line
# per unit in every region, as `open-deploy-pr.sh --pins <service>` prints them (<pin>: digest,
# tag:<name> or unparseable).
#
# - Guard: EVERY unit must pin tag:master. java-service-release.yml deploys by moving :master and
#   forcing a new ECS deployment, so a unit that pins a digest or another tag would not follow
#   the release, and a line that is unparseable or missing (no units at all) cannot be shown to.
#   Any such unit exits 3 with an ::error:: naming the units, before any AWS call: nothing is
#   retagged and nothing in prod changes.
# - Retag: sha-<7> is tagged master with scripts/ecr-retag.sh (same manifest, no rebuild). A
#   re-run on the same merge (master already names that image) exits 0.
#
# Prints the digest as the last stdout line, and writes digest=<digest> to GITHUB_OUTPUT when set.
# Exit: 0 retagged (digest printed); 1 aws failure; 2 sha-<7> not in ECR (never rebuilt);
# 3 a prod unit does not pin :master (no AWS call); 64 usage.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
usage() { echo "release-image: $1" >&2; echo "usage: release-image.sh <service> <merge-sha> < pins" >&2; exit 64; }
[ $# -eq 2 ] || usage "expected 2 arguments, got $#"
svc=$1 merge=$2
[[ $svc =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage "bad service name '$svc'"
[[ $merge =~ ^[0-9a-f]{40}$ ]] || usage "merge-sha must be 40 hex (got '$merge')"
from=sha-${merge:0:7}
to=master

blockers="" units=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  units=$((units + 1))
  path=${line%% *} pin=${line#* }
  if [ "$path" = "$line" ] || ! [[ $pin =~ ^(digest|tag:[A-Za-z0-9_][A-Za-z0-9_.-]*)$ ]]; then
    blockers="$blockers ${path} (unparseable: '${pin}');"
  elif [ "$pin" != "tag:$to" ]; then
    blockers="$blockers $path (pins $pin);"
  fi
done
[ "$units" -gt 0 ] || blockers=" (no prod units listed);"

if [ -n "$blockers" ]; then
  echo "::error::$svc is not released: every prod unit must pin :$to, so that the forced deployment runs the merged image, and these do not:${blockers%;}. Nothing was retagged and nothing in prod changed."
  exit 3
fi
digest=$(bash "$HERE/ecr-retag.sh" "$svc" "$from" "$to"); rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
[ -z "${GITHUB_OUTPUT:-}" ] || echo "digest=$digest" >> "$GITHUB_OUTPUT"
echo "$digest"
