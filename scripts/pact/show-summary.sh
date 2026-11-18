#!/usr/bin/env bash
# Usage: show-summary.sh <report-dir> <pacts-dir> <provider>
# 1. Prints every line of <report-dir>/*.txt that starts with ::notice::, ::warning:: or ::error::, so
#    GitHub turns them into annotations (Gradle hides test stdout, so a provider build writes them to files).
#    A notice is printed when there are none.
# 2. Counts the pact files oci-pull.sh fetched, at any depth under <pacts-dir> (*.json), for this provider
#    only (.provider.name == <provider>), per consumer (.consumer.name). Consumers whose name ends in
#    `.pending` are ignored; a missing or non-string consumer name counts as a consumer no line can
#    cover (fail-closed). Non-pact JSON (not an object with an interactions array) is skipped with a notice.
# 3. For each consumer c with k_c pacts, <report-dir>/summary.txt MUST hold lines
#    `::notice::verified <n> active pacts from <c> under <folder>` (n up to 6 digits) whose n sum to k_c
#    or more. Otherwise it prints ::error::fetched <k> consumer pacts from <c> but the build verified <n>;...
#    and exits 1, so a provider check cannot pass while verifying nothing.
# 4. With nothing fetched (nothing published or granted yet) it prints a notice and exits 0.
set -uo pipefail
[ $# -eq 3 ] || { echo "usage: show-summary.sh <report-dir> <pacts-dir> <provider>" >&2; exit 2; }
dir=$1 pacts=$2 provider=$3
shopt -s nullglob
files=("$dir"/*.txt)
found=0
if [ ${#files[@]} -gt 0 ]; then
  lines=$(grep -hE '^::(notice|warning|error)::' "${files[@]}" 2>/dev/null || true)
  if [ -n "$lines" ]; then printf '%s\n' "$lines"; found=1; fi
fi
[ "$found" = 1 ] || echo "::notice::no contract verification summary found under $dir"

names=""
if [ -d "$pacts" ]; then
  while IFS= read -r f; do
    if ! jq -e 'type == "object" and (.interactions | type) == "array"' "$f" >/dev/null 2>&1; then
      echo "::notice::skipping non-pact JSON $f"
      continue
    fi
    # prints "c:<consumer name>" for this provider's pact, nothing for another provider's
    tagged=$(jq -r --arg p "$provider" 'select(.provider.name == $p) | "c:" + (.consumer.name | if type == "string" then . else "" end)' "$f" 2>/dev/null || true)
    [ -n "$tagged" ] || continue
    name=${tagged#c:}
    case $name in *.pending) continue ;; esac
    names="$names$name"$'\n'
  done < <(find "$pacts" -type f -name '*.json' | sort)
fi
if [ -z "$names" ]; then
  echo "::notice::no consumer pacts were fetched (none published or granted yet); nothing to verify"
  exit 0
fi
verified_lines=""
[ ! -f "$dir/summary.txt" ] || verified_lines=$(sed -nE 's/^::notice::verified ([0-9]{1,6}) active pacts from (.+) under .*$/\1 \2/p' "$dir/summary.txt")
rc=0
while IFS=$'\t' read -r k consumer; do
  verified=$(awk -v c="$consumer" '{ n = $1; sub(/^[0-9]+ /, ""); if ($0 == c) s += n } END { print s + 0 }' <<<"$verified_lines")
  if [ "$verified" -lt "$k" ]; then
    echo "::error::fetched $k consumer pacts from $consumer but the build verified $verified; the provider's contract test did not run or did not load them (the build may also have failed earlier)"
    rc=1
  fi
done < <(printf '%s' "$names" | awk '{ c[$0]++ } END { for (k in c) printf "%d\t%s\n", c[k], k }')
exit $rc
