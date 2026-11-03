#!/usr/bin/env bash
# Tests parse-pt-line.sh, paired-tests-check.sh and rerun-paired-tests.sh with stub `gh` and
# `pt-ref` (scripts/fixtures/paired-tests/bin) first on PATH, so nothing touches GitHub.
# Each case checks the exit code, text in the output, and (where named) the logged calls.
# Usage: bash scripts/test-paired-tests.sh   (exit 0 when every case passes)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FIX=$HERE/fixtures/paired-tests
export PATH="$FIX/bin:$PATH"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GH_LOG=$T/gh.log PT_LOG=$T/pt.log GH_STATE=$T GITHUB_OUTPUT=$T/out
unset GITHUB_ACTIONS GH_TOKEN

x40() { printf "$1%.0s" $(seq 40); }
P=$(x40 b) O=$(x40 c) M=$(x40 1) A=$(x40 a) U=$(x40 f) HS=$(x40 2) BS=$(x40 3)
PAIRED="platform-tests#2 via example-service#1"
R=example-service
status=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; status=1; }

# run <name> <want-exit> <cmd...>: runs with fresh logs; output (stdout+stderr) in $out.
run() {
  local name=$1 want=$2; shift 2
  : > "$GH_LOG"; : > "$PT_LOG"; : > "$GITHUB_OUTPUT"; rm -f "$T"/*.count
  out=$("$@" 2>&1); code=$?
  if [ "$code" = "$want" ]; then pass "$name"; else fail "$name" "exit $code want $want; output: $out"; fi
}
has()     { if [[ $out == *"$2"* ]]; then pass "$1"; else fail "$1" "output lacks '$2': $out"; fi; }
logs()    { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1" "$(basename "$2") lacks '$3': $(cat "$2")"; fi; }
nologs()  { if grep -qF -- "$3" "$2"; then fail "$1" "$(basename "$2") has '$3'"; else pass "$1"; fi; }
empty()   { if [ -s "$2" ]; then fail "$1" "$(basename "$2") not empty: $(cat "$2")"; else pass "$1"; fi; }
is()      { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got '$(printf '%q' "$2")' want '$3'"; fi; }
outputs() { if grep -qxF -- "$2" "$GITHUB_OUTPUT"; then pass "$1"; else fail "$1" "GITHUB_OUTPUT lacks '$2': $(cat "$GITHUB_OUTPUT")"; fi; }

PARSE="$HERE/parse-pt-line.sh" CHECK="$HERE/paired-tests-check.sh" RERUN="$HERE/rerun-paired-tests.sh"
# shellcheck disable=SC2329  # invoked through run
parse() { printf '%b' "$1" | bash "$PARSE"; }

# --- parse-pt-line.sh
run "parse: one line"                0 parse "x\nplatform-tests: $P $PAIRED\ny\n"
is "parse: prints the sha" "$out" "$P"
run "parse: no line"                 0 parse "Evidence: none\n"
is "parse: no line prints nothing" "$out" ""
run "parse: CRLF and indent"         0 parse "a\r\n   platform-tests: $P $PAIRED\r\nb\r\n"
is "parse: CRLF sha clean" "$out" "$P"
run "parse: two distinct shas"       3 parse "platform-tests: $O x\nplatform-tests: $P x\n"
run "parse: same sha twice"          0 parse "platform-tests: $P x\nplatform-tests: $P x\n"
is "parse: same sha twice prints once" "$out" "$P"
run "parse: short sha ignored"       0 parse "platform-tests: abc123 master\n"
is "parse: short sha prints nothing" "$out" ""

# --- paired-tests-check.sh
# 1. Dependabot: no issue number, base develop, no line -> pass, no resolver, no graphql.
run "1 dependabot passes"            0 bash "$CHECK" $R 1
nologs "1 no graphql call" "$GH_LOG" graphql
empty  "1 pt-ref not called" "$PT_LOG"
run "1 gate: no token needed"        0 bash "$CHECK" --gate $R 1
outputs "1 gate output needed=false" "needed=false"
nologs "1 gate no graphql" "$GH_LOG" graphql
empty  "1 gate pt-ref not called" "$PT_LOG"
run "gate: paired branch needs token" 0 bash "$CHECK" --gate $R 2
outputs "gate output needed=true" "needed=true"
run "gate: release PR needs token"   0 bash "$CHECK" --gate $R 13
outputs "gate release needed=true" "needed=true"

# 2. Paired, body sha = resolved head.
PT_OUT="$P $PAIRED" run "2 paired match passes" 0 bash "$CHECK" $R 2
has "2 notice names the sha" "$P"
logs "2 pt-ref called with the head ref" "$PT_LOG" "$R fix/1-example"
# 3. Paired, body sha is an older head.
PT_OUT="$P $PAIRED" run "3 stale sha fails" 1 bash "$CHECK" $R 3
has "3 names the expected sha" "$P"
has "3 names the found sha" "$O"
has "3 names the source" "platform-tests#2"
# 4. Paired, no line.
PT_OUT="$P $PAIRED" run "4 paired without line fails" 1 bash "$CHECK" $R 4
has "4 says paste the summary" "paste the platform-tests summary"
has "4 names the expected line" "platform-tests: $P $PAIRED"
# 5. Unpaired with a line: must be in master's history.
PT_OUT="$M master" run "5 ancestor (ahead) passes"   0 bash "$CHECK" $R 5
logs "5 compares against master" "$GH_LOG" "repos/PlantechHubDev/platform-tests/compare/$A...master"
PT_OUT="$M master" run "5 identical passes"          0 bash "$CHECK" $R 8
PT_OUT="$M master" run "5 diverged fails"            1 bash "$CHECK" $R 6
has "5 diverged names master" "master"
PT_OUT="$M master" run "5 behind fails"              1 bash "$CHECK" $R 7
PT_OUT="$M master" run "5 unknown commit (404) fails" 1 bash "$CHECK" $R 9
has "5 404 names the sha" "$U"
PT_OUT="$M master" run "unpaired without line passes" 0 bash "$CHECK" $R 15
logs "unpaired with issue still resolves" "$PT_LOG" "$R feat/40-thing"
# 6. Resolver error passes through.
PT_EXIT=2 PT_ERR="pt-ref: platform-tests#3 has no open PR closing it" \
  run "6 resolver error exits 2" 2 bash "$CHECK" $R 2
has "6 resolver message passed through" "platform-tests#3 has no open PR closing it"
PT_OUT="garbage" run "6b malformed resolver output exits 2" 2 bash "$CHECK" $R 2
# 7. Two distinct lines.
PT_OUT="$P $PAIRED" run "7 two lines fail" 1 bash "$CHECK" $R 11
has "7 says more than one line" "more than one platform-tests line"
# 8. Release mode on a prod base.
PT_OUT="$M master" run "8 release PR (master) passes" 0 bash "$CHECK" $R 13
logs "8 pt-ref --release base..head" "$PT_LOG" "$R --release $BS..$HS"
PT_OUT="$M master" run "8 release PR (main) passes"   0 bash "$CHECK" $R 16
logs "8 main uses --release" "$PT_LOG" "$R --release $BS..$HS"
# Extra cases.
PT_OUT="$P $PAIRED" run "CRLF body passes"         0 bash "$CHECK" $R 14
PT_OUT="$P $PAIRED" run "same sha twice passes"    0 bash "$CHECK" $R 12
PT_OUT="$P $PAIRED" run "owner/repo form accepted" 0 bash "$CHECK" PlantechHubDev/$R 2
logs "owner stripped for pt-ref" "$PT_LOG" "$R fix/1-example"
run "PR read fails exits 2"                        2 bash "$CHECK" $R 99
run "usage exits 64"                               64 bash "$CHECK" $R

# --- rerun-paired-tests.sh
RR=PlantechHubDev/$R
# 9. Completed run: re-run the paired-tests job of the newest run.
run "9 rerun completed run" 0 bash "$RERUN" $RR 20
logs "9 POST jobs/77/rerun" "$GH_LOG" "-X POST repos/$RR/actions/jobs/77/rerun"
logs "9 looks up ci.yml runs for the head" "$GH_LOG" "repos/$RR/actions/workflows/ci.yml/runs?head_sha=$(x40 4)&event=pull_request"
logs "9 lists up to 100 jobs" "$GH_LOG" "repos/$RR/actions/runs/500/jobs?per_page=100"
nologs "9 older run untouched" "$GH_LOG" "runs/499/jobs"
run "rerun: no run found exits 0" 0 bash "$RERUN" $RR 21
has "rerun: no run note" "no ci.yml run"
nologs "rerun: no run, no POST" "$GH_LOG" POST
run "rerun: no paired-tests job exits 1" 1 bash "$RERUN" $RR 22
has "rerun: names the missing job" "no paired-tests job"
nologs "rerun: no job, no POST" "$GH_LOG" POST
PAIRED_TESTS_POLL_INTERVAL=0 run "rerun: waits for in-progress run" 0 bash "$RERUN" $RR 23
logs "rerun: POST jobs/78 after second poll" "$GH_LOG" "-X POST repos/$RR/actions/jobs/78/rerun"
is "rerun: polled twice" "$(grep -c 'actions/workflows/ci.yml/runs' "$GH_LOG")" 2
PAIRED_TESTS_POLL_INTERVAL=0 PAIRED_TESTS_POLL_TIMEOUT=0 \
  run "rerun: times out exits 1" 1 bash "$RERUN" $RR 24
has "rerun: says timed out" "timed out"
run "rerun: usage exits 64" 64 bash "$RERUN" $R 20

exit $status
