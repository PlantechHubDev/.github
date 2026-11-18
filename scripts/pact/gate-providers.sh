#!/usr/bin/env bash
# Usage: gate-providers.sh <gate-dir> <consumer> <pacts-dir> <provider>...   (env BASE_REF, DEFAULT_BRANCH)
# Runs gate.sh for each provider on <pacts-dir>/<consumer>-<provider>.json, using what oci-pull.sh
# pulled into <gate-dir> (layout <gate-dir>/<package>/<file>):
#   <gate-dir>/pacts-<consumer>/<consumer>-<provider>.json        default-branch pact (optional)
#   <gate-dir>/pact-results-<provider>/pact-results.json          provider results (optional)
# A provider whose pact the build did not write is skipped with a notice. Exits 1 if any gate fails.
set -uo pipefail
[ $# -ge 4 ] || { echo "usage: gate-providers.sh <gate-dir> <consumer> <pacts-dir> <provider>..." >&2; exit 2; }
dir=$1 consumer=$2 pacts=$3; shift 3
here=$(cd "$(dirname "$0")" && pwd)
name_re='^[a-z0-9][a-z0-9._-]*$'
for n in "$consumer" "$@"; do
  [[ $n =~ $name_re ]] || { echo "::error::Invalid name '$n' (lower-case letters, digits, dots, dashes, underscores)"; exit 2; }
done
rc=0
for provider in "$@"; do
  new=$pacts/$consumer-$provider.json
  if [ ! -f "$new" ]; then
    echo "::notice::No $new written by the build; contract gate for $provider skipped"
    continue
  fi
  base=$dir/pacts-$consumer/$consumer-$provider.json
  results=$dir/pact-results-$provider/pact-results.json
  [ -f "$base" ] || base=""
  [ -f "$results" ] || results=""
  bash "$here/gate.sh" "$provider" "$new" "$base" "$results" || rc=1
done
exit $rc
