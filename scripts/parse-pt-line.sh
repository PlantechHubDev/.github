#!/usr/bin/env bash
# parse-pt-line.sh: read a PR body on stdin and print the sha from its platform-tests line
# (the first line of the platform-tests run summary, "platform-tests: <40-hex sha> <source>").
# Leading whitespace and CRLF line endings are tolerated (web-edited PR bodies use CRLF).
# Prints nothing when there is no such line.
# Exit: 0 ok (same sha repeated is fine), 3 more than one distinct sha (an old paste left in).
set -euo pipefail

shas=$(tr -d '\r' | sed -nE 's/^[[:space:]]*platform-tests: ([0-9a-f]{40}).*/\1/p' | sort -u)
count=$(printf '%s' "$shas" | grep -c . || true)
if [ "$count" -gt 1 ]; then
  echo "parse-pt-line: more than one platform-tests line with different shas: ${shas//$'\n'/ }" >&2
  exit 3
fi
[ -z "$shas" ] || printf '%s\n' "$shas"
