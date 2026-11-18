#!/usr/bin/env bash
# Usage: results.sh <provider> <pacts-root> <reports-dir> <sha>
# Prints the provider's contract results as JSON on stdout:
#   {"provider","sha","interactions":[{"consumer","source","description","digest","status"}]}
# status is passed or failed. <pacts-root> has one folder per source (`default`, `pr-<n>`) holding
# <package>/<consumer>-<provider>.json (the layout oci-pull.sh produces); an interaction's digest is
# digest.sh's. The verification reports are pact-jvm JSON reports (pact.provider.reports=json), one
# run per source folder, read from <reports-dir>/<source>/*.json. An interaction is passed only when
# a report lists it (matched by consumer name and description) with verification.result "OK";
# absent from every report, it is failed and a ::warning:: is printed (fail-closed). Failures never
# make this script fail.
set -euo pipefail
[ $# -eq 4 ] || { echo "usage: results.sh <provider> <pacts-root> <reports-dir> <sha>" >&2; exit 2; }
provider=$1 root=$2 reports=$3 sha=$4
here=$(cd "$(dirname "$0")" && pwd)
[[ $provider =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { echo "::error::Invalid provider name '$provider'" >&2; exit 2; }
shopt -s nullglob
entries=()
for srcdir in "$root"/*/; do
  source=$(basename "$srcdir")
  repfiles=("$reports/$source"/*.json)
  if [ ${#repfiles[@]} -gt 0 ]; then
    # one array of {consumer, description, result} across every report file for this source
    verified=$(jq -s '[.[] | (.execution // [])[] | .consumer.name as $c | (.interactions // [])[]
      | {consumer: $c, description: .interaction.description, result: .verification.result}]' "${repfiles[@]}")
  else
    echo "::warning::No verification report in $reports/$source; every $provider interaction from $source is recorded as failed" >&2
    verified='[]'
  fi
  for pact in "$srcdir"*/*.json; do
    [ "$(jq -r '.provider.name' "$pact")" = "$provider" ] || continue
    consumer=$(jq -r '.consumer.name' "$pact")
    while read -r digest desc; do
      status=$(jq -r --arg c "$consumer" --arg d "$desc" '[.[] | select(.consumer == $c and (.description | gsub("[\n\r]"; " ")) == $d)]
        | if length > 0 and all(.[]; .result == "OK") then "passed" else "failed" end' <<<"$verified")
      if [ "$status" = failed ] && ! jq -e --arg c "$consumer" --arg d "$desc" 'any(.[]; .consumer == $c and (.description | gsub("[\n\r]"; " ")) == $d)' <<<"$verified" >/dev/null; then
        echo "::warning::$source: '$desc' ($consumer) is in the pact but not in the verification report; recorded as failed" >&2
      fi
      entries+=("$(jq -n -c --arg c "$consumer" --arg s "$source" --arg d "$desc" --arg g "$digest" --arg st "$status" \
        '{consumer: $c, source: $s, description: $d, digest: $g, status: $st}')")
    done < <(bash "$here/digest.sh" "$pact" | sed 's/^\([0-9a-f]\{64\}\)  /\1 /')
  done
done
if [ ${#entries[@]} -gt 0 ]; then list=$(printf '%s\n' "${entries[@]}" | jq -s '.'); else list='[]'; fi
jq -n --arg p "$provider" --arg s "$sha" --argjson i "$list" '{provider: $p, sha: $s, interactions: $i}'
