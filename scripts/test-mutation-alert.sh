#!/usr/bin/env bash
# Tests mutation-alert.sh with a stub `gh` (scripts/fixtures/mutation-alert/bin) first on PATH,
# so nothing touches GitHub. Case directories: none/ (no open red issue), open/ (#42 open).
# Usage: bash scripts/test-mutation-alert.sh   (exit 0 when every case passes)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FIX=$HERE/fixtures/mutation-alert
export PATH="$FIX/bin:$PATH"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GH_LOG=$T/gh.log
unset GITHUB_ACTIONS GH_TOKEN MA_LOG
ALERT="$HERE/mutation-alert.sh"
R=example/example-service
URL=https://github.com/example/example-service/actions/runs/123
status=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; status=1; }

# run <name> <case> <want-exit> <result>: fresh logs; output in $out.
run() {
  local name=$1 case=$2 want=$3 result=$4
  : > "$GH_LOG"; : > "$GH_LOG.body"
  out=$(MA_CASE="$FIX/$case" bash "$ALERT" "$R" 123 "$URL" "$result" 2>&1); code=$?
  if [ "$code" = "$want" ]; then pass "$name"; else fail "$name" "exit $code want $want; output: $out"; fi
}
count()  { local n; n=$(grep -cF -- "$3" "$GH_LOG"); if [ "$n" = "$2" ]; then pass "$1"; else fail "$1" "$n calls with '$3', want $2: $(cat "$GH_LOG")"; fi; }
body()   { if grep -qF -- "$2" "$GH_LOG.body"; then pass "$1"; else fail "$1" "body lacks '$2': $(cat "$GH_LOG.body")"; fi; }
nobody() { if grep -qF -- "$2" "$GH_LOG.body"; then fail "$1" "body has '$2'"; else pass "$1"; fi; }
nowrite() {
  if grep -qE '^(issue (create|comment|close)|label create)' "$GH_LOG"; then fail "$1" "write call: $(cat "$GH_LOG")"; else pass "$1"; fi
}

# 1. First failure: exactly one issue, with title, labels, failing step, run link and the log tail.
run "1 failure, none open"          none 0 failure
count "1 one create"                1 "issue create"
count "1 no comment"                0 "issue comment"
count "1 title"                     1 "--title mutation-nightly red: example-service"
count "1 labels"                    1 "--label bug --label area:test-infra --label priority:P1"
body  "1 failing step named"        'Run PIT'
body  "1 run link"                  "$URL"
body  "1 last log line"             "tests fail under PIT without mutation"
body  "1 log tail kept"             "log line 40"
nobody "1 log cut to 30 lines"      "log line 12"
body  "1 fence survives backticks"  '~~~~'
nobody "1 post-step lines cut"     "Post job cleanup"
nobody "1 earlier steps cut"        "changes line"
count "1 lookup by title, not label" 0 "issue list --repo $R --state open --label"
count "1 lookup by title search"    1 'issue list --repo example/example-service --state open --search in:title "mutation-nightly red: example-service"'
nobody "1 next step in same second cut" "upload-artifact"
count "1 search-lag fallback list"   1 "issue list --repo $R --state open --limit 1000 --json number,title"
body  "1 step exit line kept"       "Process completed with exit code 1."
body  "1 heading names the step"    "Last 30 lines of the failing step's log"
# 2. Second failure: one comment on #42, no new issue.
run "2 failure, #42 open"           open 0 failure
count "2 no create"                 0 "issue create"
count "2 comment on #42"            1 "issue comment 42"
count "2 no fallback when found"     0 "--limit 1000"
body  "2 comment names step"        'Run PIT'
# 3. Cancelled or timed out counts as red.
run "3 cancelled, none open"        none 0 cancelled
count "3 one create"                1 "issue create"
# 4. Green with #42 open: closed with the green run's link.
run "4 success, #42 open"           open 0 success
count "4 close #42"                 1 "issue close 42"
count "4 no create"                 0 "issue create"
count "4 close comment links run"   1 "issue close 42 --repo $R --comment The nightly is green again: $URL"
# 5. Green with none open: no writes.
run "5 success, none open"          none 0 success
nowrite "5 nothing written"
# 6. Skipped (mutation job never ran): no calls at all.
run "6 skipped"                     none 0 skipped
count "6 no gh calls"               0 " "
# 7. Log unavailable: still opens the issue and says so.
: > "$GH_LOG"; : > "$GH_LOG.body"
out=$(MA_CASE="$FIX/none" MA_LOG=/nonexistent bash "$ALERT" "$R" 123 "$URL" failure 2>&1); code=$?
if [ "$code" = 0 ]; then pass "7 no log still exits 0"; else fail "7 no log" "exit $code: $out"; fi
count "7 one create"                1 "issue create"
body  "7 says log unavailable"      "log unavailable"
# 8. Bad arguments fail loudly.
run "8 unknown result"              none 2 bogus
: > "$GH_LOG"
out=$(bash "$ALERT" "$R" 123 2>&1); code=$?
if [ "$code" = 2 ]; then pass "8 missing args exit 2"; else fail "8 missing args" "exit $code"; fi
exit $status
