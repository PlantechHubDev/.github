#!/usr/bin/env bash
# Usage: show-summary.sh <report-dir> <pacts-dir>
# 1. Prints every line of <report-dir>/*.txt that starts with ::notice::, ::warning:: or ::error::, so
#    GitHub turns them into annotations (Gradle hides test stdout, so a provider build writes them to files).
#    A notice is printed when there are none.
# 2. Counts the pact files oci-pull.sh fetched, <pacts-dir>/*/*.json, ignoring those whose .consumer.name
#    ends in `.pending`. When that count k is above 0, the build MUST have verified at least k of them:
#    <report-dir>/summary.txt must hold lines `::notice::verified <n> active pacts from <consumer> under <folder>`
#    whose n add up to k or more. Otherwise it prints ::error::fetched <k> consumer pacts but the build
#    verified <n>; ... and exits 1, so a provider check cannot pass while verifying nothing.
# 3. With nothing fetched (nothing published or granted yet) it prints a notice and exits 0.
set -uo pipefail
[ $# -eq 2 ] || { echo "usage: show-summary.sh <report-dir> <pacts-dir>" >&2; exit 2; }
dir=$1 pacts=$2
shopt -s nullglob
files=("$dir"/*.txt)
found=0
if [ ${#files[@]} -gt 0 ]; then
  lines=$(grep -hE '^::(notice|warning|error)::' "${files[@]}" 2>/dev/null || true)
  if [ -n "$lines" ]; then printf '%s\n' "$lines"; found=1; fi
fi
[ "$found" = 1 ] || echo "::notice::no contract verification summary found under $dir"

fetched=0
for f in "$pacts"/*/*.json; do
  name=$(jq -r '.consumer.name // ""' "$f" 2>/dev/null || true)
  case $name in *.pending) continue ;; esac
  fetched=$((fetched + 1))
done
if [ "$fetched" -eq 0 ]; then
  echo "::notice::no consumer pacts were fetched (none published or granted yet); nothing to verify"
  exit 0
fi
verified=0
if [ -f "$dir/summary.txt" ]; then
  verified=$(sed -nE 's/^::notice::verified ([0-9]+) active pacts from .*/\1/p' "$dir/summary.txt" | awk '{ s += $1 } END { print s + 0 }')
fi
if [ "$verified" -lt "$fetched" ]; then
  echo "::error::fetched $fetched consumer pacts but the build verified $verified; the provider's contract test did not run or did not load them"
  exit 1
fi
exit 0
