#!/usr/bin/env bash
# release-image.sh <service> <merge-sha> < pins: pick the image to deploy, <service>:sha-<first 7 of
# merge-sha> (the image the merge queue built and simulated), and tag it master only when that is
# safe. stdin is the service's prod units on the infrastructure repo's master, one "<path> <pin>" line
# per unit in every region, as `open-deploy-pr.sh --pins <service>` prints them (<pin>: digest,
# tag:<name> or unparseable).
#
# - If ANY unit pins tag:master, or any line is unparseable, garbled or missing (no units at
#   all), the retag is SKIPPED with a ::warning:: naming those units, and the digest is read
#   read-only. A unit pinning :master pulls it on every task start or scale-up, and ECR
#   replication moves :master in every region, so moving it would put an unapproved image into
#   prod. This fails closed: whatever cannot be read as safe means no retag.
# - Otherwise sha-<7> is retagged as master with scripts/ecr-retag.sh (no rebuild).
#
# Prints the digest as the last stdout line. When GITHUB_OUTPUT is set, writes digest=<digest>,
# retagged=true|false (whether :master was moved to it) and held-by=<space-separated unit paths
# that kept :master from moving; empty when retagged or when no units were listed) there, for
# the deploy PR's body (open-deploy-pr.sh RETAGGED, HELD_BY).
# Exit: 0 digest printed; 1 aws failure; 2 sha-<7> not in ECR (never rebuilt; no PR should open);
# 64 usage.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
usage() { echo "release-image: $1" >&2; echo "usage: release-image.sh <service> <merge-sha> < pins" >&2; exit 64; }
[ $# -eq 2 ] || usage "expected 2 arguments, got $#"
svc=$1 merge=$2
[[ $svc =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage "bad service name '$svc'"
[[ $merge =~ ^[0-9a-f]{40}$ ]] || usage "merge-sha must be 40 hex (got '$merge')"
from=sha-${merge:0:7}
to=master

blockers="" held="" units=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  units=$((units + 1))
  path=${line%% *} pin=${line#* }
  if [ "$path" = "$line" ] || ! [[ $pin =~ ^(digest|tag:[A-Za-z0-9_][A-Za-z0-9_.-]*)$ ]]; then
    blockers="$blockers ${path} (unparseable: '${pin}')" held="$held $path"
  elif [ "$pin" = "tag:$to" ]; then
    blockers="$blockers $path (pins :$to)" held="$held $path"
  fi
done
[ "$units" -gt 0 ] || blockers=" (no prod units listed)"

if [ -n "$blockers" ]; then
  echo "::warning::$svc:$to is not moved, because these prod units pin it or cannot be read:$blockers. A task start would run an unapproved image (ECR replication moves the tag in every region). The deploy PR pins $from by digest; :$to moves again once every prod unit pins a digest."
  digest=$(bash "$HERE/ecr-existing-digest.sh" "$svc" "$from") || { echo "release-image: cannot read $svc:$from in ECR" >&2; exit 1; }
  [ -n "$digest" ] || { echo "release-image: $svc:$from not found in ECR; nothing is rebuilt and no deploy PR opens" >&2; exit 2; }
  retagged=false
else
  digest=$(bash "$HERE/ecr-retag.sh" "$svc" "$from" "$to"); rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  retagged=true
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "digest=$digest"; echo "retagged=$retagged"; echo "held-by=${held# }"; } >> "$GITHUB_OUTPUT"
fi
echo "$digest"
