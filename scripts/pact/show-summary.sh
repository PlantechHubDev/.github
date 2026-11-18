#!/usr/bin/env bash
# Usage: show-summary.sh <report-dir> <pacts-dir> <provider>   (<provider> MUST equal the pacts' .provider.name)
# 1. Prints every line of <report-dir>/*.txt that starts with ::notice::, ::warning:: or ::error::, so
#    GitHub turns them into annotations (Gradle hides test stdout, so a provider build writes them to files).
#    A notice is printed when there are none.
# 2. Counts the pact files oci-pull.sh fetched, at any depth under <pacts-dir> (*.json), per source folder
#    and consumer, for this provider only (.provider.name == <provider>). The source folder is the first path
#    component under <pacts-dir> when it is `default` or `pr-<n>`, else `.` (flat layout). Consumers whose
#    name ends in `.pending` are ignored; a missing or non-string consumer name counts as a consumer no line
#    can cover (fail-closed). Non-pact JSON (not an object with an interactions array) is skipped with a notice.
#    If pacts were fetched but none name <provider>, that is an error (a provider-name mismatch must not pass
#    silently); a fetched package with pacts but none for <provider> only warns.
# 3. For each (folder, consumer) with k pacts, <report-dir>/summary.txt MUST hold lines
#    `::notice::verified <n> active pacts from <consumer> under <folder>` (n up to 6 digits, consumer without
#    spaces) whose n sum to k or more. A line's <folder> matches by its last path component (so
#    `$RUNNER_TEMP/pacts/default` matches `default`); in the flat layout the folder is not compared.
#    Otherwise it prints ::error::fetched <k> consumer pacts from <consumer> ... and exits 1, so a provider
#    check cannot pass while verifying nothing.
# 4. With nothing fetched (nothing published or granted yet) it prints a notice and exits 0.
set -uo pipefail
[ $# -eq 3 ] || { echo "usage: show-summary.sh <report-dir> <pacts-dir> <provider>" >&2; exit 2; }
dir=$1 pacts=$2 provider=$3
[[ $provider =~ ^[A-Za-z0-9._-]+$ ]] || { echo "::error::Invalid provider name '$provider' (the service input must be letters, digits, dots, dashes, underscores)"; exit 2; }
tab=$'\t'
shopt -s nullglob
files=("$dir"/*.txt)
found=0
if [ ${#files[@]} -gt 0 ]; then
  lines=$(grep -hE '^::(notice|warning|error)::' "${files[@]}" 2>/dev/null || true)
  if [ -n "$lines" ]; then printf '%s\n' "$lines"; found=1; fi
fi
[ "$found" = 1 ] || echo "::notice::no contract verification summary found under $dir"

# recs: one line per valid pact, "<folder>\t<package>\t<provider>\t<consumer>" (tabs and newlines in names blanked)
recs=""
if [ -d "$pacts" ]; then
  while IFS= read -r -d '' f; do
    if ! jq -e 'type == "object" and (.interactions | type) == "array"' "$f" >/dev/null 2>&1; then
      echo "::notice::skipping non-pact JSON $f"
      continue
    fi
    rel=${f#"$pacts"/}
    first=${rel%%/*}
    if [[ $first == default || $first =~ ^pr-[0-9]+$ ]] && [ "$first" != "$rel" ]; then
      folder=$first; rest=${rel#*/}
    else
      folder=.; rest=$rel
    fi
    package=${rest%%/*}
    rec=$(jq -r --arg f "$folder" --arg k "$package" '[$f, $k,
        ((.provider.name | if type == "string" then . else "" end) | gsub("[\t\n\r]"; " ")),
        ((.consumer.name | if type == "string" then . else "" end) | gsub("[\t\n\r]"; " "))] | join("\t")' "$f" 2>/dev/null || true)
    [ -n "$rec" ] || continue
    recs="$recs$rec"$'\n'
  done < <(find "$pacts" -type f -name '*.json' -print0)
fi
if [ -z "$recs" ]; then
  echo "::notice::no consumer pacts were fetched (none published or granted yet); nothing to verify"
  exit 0
fi
total=$(printf '%s' "$recs" | grep -c '^')
mine=$(printf '%s' "$recs" | awk -F'\t' -v p="$provider" '$3 == p' )
if [ -z "$mine" ]; then
  names=$(printf '%s' "$recs" | awk -F'\t' '{ print $3 }' | sort -u | paste -sd, - | sed 's/,/, /g')
  echo "::error::fetched $total pacts but none for provider '$provider' (found: $names)"
  exit 1
fi
printf '%s' "$recs" | awk -F'\t' -v p="$provider" '
  { key = $1 "\t" $2; seen[key] = 1; if ($3 == p) hit[key] = 1 }
  END { for (k in seen) if (!(k in hit)) { split(k, a, "\t"); print a[2] } }' | sort -u | while IFS= read -r pkg; do
  echo "::warning::package $pkg holds pacts but none for provider '$provider'"
done

verified_lines=""
[ ! -f "$dir/summary.txt" ] || verified_lines=$(sed -nE "s/^::notice::verified ([0-9]{1,6}) active pacts from ([^ ]+) under (.+)\$/\1${tab}\2${tab}\3/p" "$dir/summary.txt")
rc=0
# one "<k>\t<folder>\t<consumer>" line per (folder, consumer) of this provider's non-pending pacts
counts=$(printf '%s\n' "$mine" | awk -F'\t' '$4 !~ /\.pending$/ { c[$1 "\t" $4]++ } END { for (k in c) printf "%d\t%s\n", c[k], k }' | sort)
while IFS= read -r line; do
  [ -n "$line" ] || continue
  k=${line%%"$tab"*}; rest=${line#*"$tab"}
  folder=${rest%%"$tab"*}; consumer=${rest#*"$tab"}
  res=$(printf '%s' "$verified_lines" | awk -F'\t' -v c="$consumer" -v f="$folder" -v k="$k" '
    { b = $3; sub(/\/+$/, "", b); sub(/.*\//, "", b); if ($2 == c && (f == "." || b == f)) s += $1 }
    END { printf "%s %d\n", ((s + 0 >= k + 0) ? "ok" : "short"), s }')
  if [ "${res%% *}" != ok ]; then
    where=""; [ "$folder" = . ] || where=" under $folder"
    echo "::error::fetched $k consumer pacts from $consumer$where but the build verified ${res#* }; the provider's contract test did not run or did not load them (the build may also have failed earlier)"
    rc=1
  fi
done <<<"$counts"
if [ -z "$counts" ]; then echo "::notice::no consumer pacts were fetched (only pending ones); nothing to verify"; fi
exit $rc
