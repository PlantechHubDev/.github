#!/usr/bin/env bash
# release-image.sh <service> <merge-sha> <pin>: pick the image to deploy, <service>:sha-<first 7 of
# merge-sha> (the image the merge queue built and simulated), and tag it master only when that is
# safe. <pin> is what infrastructure-live master pins for the prod unit now, as printed by
# `open-deploy-pr.sh --base-digest` (second field): `digest` or `tag:<name>`.
#
# - pin tag:master: prod pulls :master on every task start, so moving :master would put an
#   unapproved image into prod at the next restart. The retag is SKIPPED (a ::warning:: says so):
#   the digest is read read-only and :master stays put until the unit pins a digest.
# - any other pin: sha-<7> is retagged as master with scripts/ecr-retag.sh (no rebuild).
#
# Prints the digest as the last stdout line, and writes digest=<digest> to $GITHUB_OUTPUT when set.
# Exit: 0 digest printed; 1 aws failure; 2 sha-<7> not in ECR (never rebuilt; no PR should open);
# 64 usage.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
usage() { echo "release-image: $1" >&2; echo "usage: release-image.sh <service> <merge-sha> <digest|tag:NAME>" >&2; exit 64; }
[ $# -eq 3 ] || usage "expected 3 arguments, got $#"
svc=$1 merge=$2 pin=$3
[[ $svc =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage "bad service name '$svc'"
[[ $merge =~ ^[0-9a-f]{40}$ ]] || usage "merge-sha must be 40 hex (got '$merge')"
[[ $pin =~ ^(digest|tag:[A-Za-z0-9_][A-Za-z0-9_.-]*)$ ]] || usage "pin must be 'digest' or 'tag:<name>' (got '$pin')"
from=sha-${merge:0:7}
to=master

if [ "$pin" = "tag:$to" ]; then
  echo "::warning::prod pins :$to for $svc, so $svc:$to is not moved (a task restart would run an unapproved image). The deploy PR pins $from by digest; :$to moves again once the unit pins a digest."
  digest=$(bash "$HERE/ecr-existing-digest.sh" "$svc" "$from") || { echo "release-image: cannot read $svc:$from in ECR" >&2; exit 1; }
  [ -n "$digest" ] || { echo "release-image: $svc:$from not found in ECR; nothing is rebuilt and no deploy PR opens" >&2; exit 2; }
else
  digest=$(bash "$HERE/ecr-retag.sh" "$svc" "$from" "$to"); rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
fi
[ -z "${GITHUB_OUTPUT:-}" ] || echo "digest=$digest" >> "$GITHUB_OUTPUT"
echo "$digest"
