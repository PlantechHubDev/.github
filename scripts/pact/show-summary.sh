#!/usr/bin/env bash
# Usage: show-summary.sh <dir>
# Prints every line of <dir>/*.txt that starts with ::notice::, ::warning:: or ::error::, so GitHub
# turns them into annotations (Gradle hides test stdout, so a provider build writes them to files).
# Prints a notice when there is none. Never fails.
set -uo pipefail
dir=${1:-build/reports/pact}
shopt -s nullglob
files=("$dir"/*.txt)
found=0
if [ ${#files[@]} -gt 0 ]; then
  lines=$(grep -hE '^::(notice|warning|error)::' "${files[@]}" 2>/dev/null || true)
  if [ -n "$lines" ]; then printf '%s\n' "$lines"; found=1; fi
fi
[ "$found" = 1 ] || echo "::notice::no contract verification summary found under $dir"
exit 0
