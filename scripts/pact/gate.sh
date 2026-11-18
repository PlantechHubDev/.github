#!/usr/bin/env bash
# Usage: gate.sh <provider> <new-pact> <base-pact|""> <results.json|"">   (env BASE_REF, DEFAULT_BRANCH)
# Fails (exit 1) when the PR's pact has an interaction that is not in the base pact (added or
# changed) and whose digest the provider's default-branch results do not list as passed.
# Skips with a notice when the PR does not target the default branch or the provider has no
# results yet. Unchanged interactions missing from the results only warn.
set -euo pipefail
[ $# -eq 4 ] || { echo "usage: gate.sh <provider> <new-pact> <base-pact|\"\"> <results.json|\"\">" >&2; exit 2; }
provider=$1 new=$2 base=$3 results=$4
here=$(cd "$(dirname "$0")" && pwd)
if [ "${BASE_REF:?}" != "${DEFAULT_BRANCH:?}" ]; then
  echo "::notice::base $BASE_REF is not the default branch; contract gate skipped"
  exit 0
fi
if [ -z "$results" ] || [ ! -f "$results" ]; then
  echo "::notice::$provider has not published contract results yet (not onboarded); gate skipped"
  exit 0
fi
base_digests=""
if [ -n "$base" ] && [ -f "$base" ]; then
  base_lines=$(bash "$here/digest.sh" "$base")
  base_digests=$(cut -d' ' -f1 <<<"$base_lines")
fi
passed=$(jq -r '.interactions[] | select(.status == "passed") | .digest' "$results")
# Captured first so a digest.sh failure (malformed or empty pact) fails the gate, not silently passes.
lines=$(bash "$here/digest.sh" "$new")
rc=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  digest=${line%%  *} desc=${line#*  }
  if grep -qxF "$digest" <<<"$base_digests"; then
    grep -qxF "$digest" <<<"$passed" || echo "::warning::'$desc' is unchanged but $provider's default branch has no passing result for it"
  elif ! grep -qxF "$digest" <<<"$passed"; then
    echo "::error::'$desc': $provider's default branch has not verified this call yet; release the provider change first, run $provider's contract-results workflow (or wait for its daily run) and re-run this check, or move this interaction to the pending suite."
    rc=1
  fi
done <<<"$lines"
exit $rc
