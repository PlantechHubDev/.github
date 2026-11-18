#!/usr/bin/env bash
# Usage: digest.sh <pact.json>
# Prints one line per interaction: "<sha256>  <description>". The digest covers only what a
# provider must honour (providerStates, request, response, keys sorted), so a reworded
# description, comments or the pending flag do not change it.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: digest.sh <pact.json>" >&2; exit 2; }
if command -v sha256sum >/dev/null 2>&1; then sum() { sha256sum; }; else sum() { shasum -a 256; }; fi
jq -e '.interactions | type == "array"' "$1" >/dev/null 2>&1 || { echo "::error::$1 is not a pact file (not valid JSON, or no interactions array)" >&2; exit 1; }
count=$(jq '.interactions | length' "$1")
i=0
while [ "$i" -lt "$count" ]; do
  digest=$(jq -S -c ".interactions[$i] | {providerStates, request, response}" "$1" | sum | cut -d' ' -f1)
  desc=$(jq -r "(.interactions[$i].description // \"\") | gsub(\"[\\n\\r]\"; \" \")" "$1")
  printf '%s  %s\n' "$digest" "$desc"
  i=$((i + 1))
done
