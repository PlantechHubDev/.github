#!/usr/bin/env bash
# Tests scripts/pact/{default-branch,oci-push,oci-pull,results}.sh with stub `oras` and `gh`
# (scripts/fixtures/pact/bin) first on PATH, so nothing touches GHCR or GitHub.
# Usage: bash scripts/test-pact.sh   (exit 0 when every case passes)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FIX=$HERE/fixtures/pact
export PATH="$FIX/bin:$PATH"
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
export FAKE_ORAS_LOG=$T/oras.log FAKE_GH_LOG=$T/gh.log FAKE_ORAS_STORE=$T/store
export GITHUB_REPOSITORY=example-org/consumer-a
unset FAKE_ORAS_CMDNOTFOUND EVENT_DEFAULT_BRANCH FAKE_GH_DEFAULT_BRANCH FAKE_ORAS_NOT_FOUND FAKE_ORAS_UNKNOWN FAKE_ORAS_DENIED FAKE_ORAS_BROKEN GITHUB_REF_NAME ORAS_REGISTRY_CONFIG
status=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; status=1; }

reset() {
  : > "$FAKE_ORAS_LOG"; : > "$FAKE_GH_LOG"; rm -rf "${T:?}/store" "${T:?}/pacts" "${T:?}/out"
  mkdir -p "$T/store/pacts-consumer-a" "$T/store/pacts-consumer-b" "$T/pacts"
  cp "$FIX/consumer-a-provider-b.json" "$T/store/pacts-consumer-a/"
  cp "$FIX/consumer-a-provider-b.json" "$T/store/pacts-consumer-b/"
  unset FAKE_ORAS_CMDNOTFOUND EVENT_DEFAULT_BRANCH FAKE_GH_DEFAULT_BRANCH FAKE_ORAS_NOT_FOUND FAKE_ORAS_UNKNOWN FAKE_ORAS_DENIED FAKE_ORAS_BROKEN GITHUB_REF_NAME ORAS_REGISTRY_CONFIG
}
# run <name> <want-exit> <cmd...>: output (stdout+stderr) in $out.
run() {
  local name=$1 want=$2; shift 2
  out=$("$@" 2>&1); code=$?
  if [ "$code" = "$want" ]; then pass "$name"; else fail "$name" "exit $code want $want; output: $out"; fi
}
has()    { if [[ $out == *"$2"* ]]; then pass "$1"; else fail "$1" "output lacks '$2': $out"; fi; }
hasnt()  { if [[ $out == *"$2"* ]]; then fail "$1" "output has '$2': $out"; else pass "$1"; fi; }
logs()   { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1" "$(basename "$2") lacks '$3': $(cat "$2")"; fi; }
nologs() { if grep -qF -- "$3" "$2"; then fail "$1" "$(basename "$2") has '$3'"; else pass "$1"; fi; }
empty()  { if [ -s "$2" ]; then fail "$1" "$(basename "$2") not empty: $(cat "$2")"; else pass "$1"; fi; }
exists() { if [ -f "$2" ]; then pass "$1"; else fail "$1" "missing $2"; fi; }

DB=$HERE/pact/default-branch.sh PUSH=$HERE/pact/oci-push.sh PULL=$HERE/pact/oci-pull.sh
RESULTS=$HERE/pact/results.sh
SUMMARY=$HERE/pact/show-summary.sh
GATEPROV=$HERE/pact/gate-providers.sh DIGEST=$HERE/pact/digest.sh GATE=$HERE/pact/gate.sh BASEREF=$HERE/pact/base-ref.sh
G=$FIX/gate
# digest_of <pact> <description>: the digest digest.sh prints for that interaction.
digest_of() { bash "$DIGEST" "$1" | grep -F -- "  $2" | head -1 | cut -d' ' -f1; }
# results <file> <status-for-changed-and-added|none> ...: write a results file with the given digests as
# "<digest>:<status>" arguments.
results() {
  local f=$1; shift
  printf '%s\n' "$@" | jq -R -s '{provider:"provider-b",sha:"abc1234",interactions:(split("\n")|map(select(length>0)|split(":")|{consumer:"consumer-a",source:"default",description:"x",digest:.[0],status:.[1]}))}' > "$f"
}
# shellcheck disable=SC2329  # gate and gate_providers are called through run()
gate_providers() { BASE_REF=develop DEFAULT_BRANCH=develop bash "$GATEPROV" "$T/gd" consumer-a "$T/build/pacts" "$@"; }
# shellcheck disable=SC2329
gate() { BASE_REF=develop DEFAULT_BRANCH=develop bash "$GATE" "$@"; }

default_branch_uses_event() {
  reset; export EVENT_DEFAULT_BRANCH=develop
  run "default_branch_uses_event" 0 bash "$DB"
  if [ "$out" = develop ]; then pass "default_branch_uses_event prints develop"; else fail "default_branch_uses_event" "got '$out'"; fi
  empty "default_branch_uses_event: gh not called" "$FAKE_GH_LOG"
}
default_branch_falls_back_to_api() {
  reset; export EVENT_DEFAULT_BRANCH="" FAKE_GH_DEFAULT_BRANCH=master
  run "default_branch_falls_back_to_api" 0 bash "$DB"
  if [ "$out" = master ]; then pass "default_branch_falls_back_to_api prints master"; else fail "default_branch_falls_back_to_api" "got '$out'"; fi
  logs "default_branch_falls_back_to_api: asks the repo" "$FAKE_GH_LOG" "repos/example-org/consumer-a"
}
default_branch_errors_when_unknown() {
  reset; export EVENT_DEFAULT_BRANCH="" FAKE_GH_DEFAULT_BRANCH=""
  run "default_branch_errors_when_unknown" 1 bash "$DB"
  has "default_branch_errors_when_unknown: error" "::error::"
}
push_on_default_branch() {
  reset; export EVENT_DEFAULT_BRANCH=develop GITHUB_REF_NAME=develop
  cp "$FIX/consumer-a-provider-b.json" "$T/pacts/"
  run "push_on_default_branch" 0 bash "$PUSH" pacts-consumer-a "$T/pacts" abcdef1234
  logs "push_on_default_branch: ref and tags" "$FAKE_ORAS_LOG" "push ghcr.io/plantechhubdev/pacts-consumer-a:default,sha-abcdef1"
  logs "push_on_default_branch: source annotation" "$FAKE_ORAS_LOG" "org.opencontainers.image.source=https://github.com/example-org/consumer-a"
  logs "push_on_default_branch: json media type" "$FAKE_ORAS_LOG" "consumer-a-provider-b.json:application/json"
}
push_skips_non_default_branch() {
  reset; export EVENT_DEFAULT_BRANCH=develop GITHUB_REF_NAME=master
  cp "$FIX/consumer-a-provider-b.json" "$T/pacts/"
  run "push_skips_non_default_branch" 0 bash "$PUSH" pacts-consumer-a "$T/pacts" abcdef1234
  has "push_skips_non_default_branch: notice" "::notice::"
  empty "push_skips_non_default_branch: no oras call" "$FAKE_ORAS_LOG"
}
push_skips_empty_dir() {
  reset; export EVENT_DEFAULT_BRANCH=develop GITHUB_REF_NAME=develop
  run "push_skips_empty_dir" 0 bash "$PUSH" pacts-consumer-a "$T/pacts" abcdef1234
  has "push_skips_empty_dir: notice" "::notice::"
  empty "push_skips_empty_dir: no oras call" "$FAKE_ORAS_LOG"
}
pull_missing_package_is_notice() {
  reset; export FAKE_ORAS_NOT_FOUND="pacts-consumer-a"
  run "pull_missing_package_is_notice" 0 bash "$PULL" "$T/out" pacts-consumer-a pacts-consumer-b
  has "pull_missing_package_is_notice: names the missing one" "::notice::pacts-consumer-a:default not readable"
  hasnt "pull_missing_package_is_notice: other not skipped" "pacts-consumer-b:default not readable"
  exists "pull_missing_package_is_notice: other pulled" "$T/out/pacts-consumer-b/consumer-a-provider-b.json"
}
pull_denied_is_notice() {
  reset; export FAKE_ORAS_DENIED="pacts-consumer-a"
  run "pull_denied_is_notice" 0 bash "$PULL" "$T/out" pacts-consumer-a pacts-consumer-b
  has "pull_denied_is_notice: notice" "::notice::pacts-consumer-a:default not readable"
  has "pull_denied_is_notice: mentions the grant" "Actions access grant"
  exists "pull_denied_is_notice: other pulled" "$T/out/pacts-consumer-b/consumer-a-provider-b.json"
}
pull_manifest_unknown_is_notice() {
  reset; export FAKE_ORAS_UNKNOWN="pacts-consumer-a"
  run "pull_manifest_unknown_is_notice" 0 bash "$PULL" "$T/out" pacts-consumer-a pacts-consumer-b
  has "pull_manifest_unknown_is_notice: notice" "::notice::pacts-consumer-a:default not readable"
  exists "pull_manifest_unknown_is_notice: other pulled" "$T/out/pacts-consumer-b/consumer-a-provider-b.json"
}
pull_all_skipped_creates_out_dir() {
  reset; export FAKE_ORAS_DENIED="pacts-consumer-a pacts-consumer-b"
  run "pull_all_skipped_creates_out_dir" 0 bash "$PULL" "$T/out" pacts-consumer-a pacts-consumer-b
  if [ -d "$T/out" ]; then pass "pull_all_skipped_creates_out_dir: dir exists"; else fail "pull_all_skipped_creates_out_dir" "$T/out missing"; fi
}
pull_uses_registry_config() {
  reset; export ORAS_REGISTRY_CONFIG="$T/auth.json"
  run "pull_uses_registry_config" 0 bash "$PULL" "$T/out" pacts-consumer-a
  logs "pull_uses_registry_config: flag passed" "$FAKE_ORAS_LOG" "--registry-config $T/auth.json"
}
pull_without_registry_config_omits_flag() {
  reset
  run "pull_without_registry_config_omits_flag" 0 bash "$PULL" "$T/out" pacts-consumer-a
  nologs "pull_without_registry_config_omits_flag: no flag" "$FAKE_ORAS_LOG" "--registry-config"
}
pull_rejects_bad_package_name() {
  reset
  run "pull_rejects_bad_package_name" 2 bash "$PULL" "$T/out" 'pacts-consumer-a;x' 
  has "pull_rejects_bad_package_name: error" "::error::"
  empty "pull_rejects_bad_package_name: no oras call" "$FAKE_ORAS_LOG"
}
push_uses_registry_config() {
  reset; export EVENT_DEFAULT_BRANCH=develop GITHUB_REF_NAME=develop ORAS_REGISTRY_CONFIG="$T/auth.json"
  cp "$FIX/consumer-a-provider-b.json" "$T/pacts/"
  run "push_uses_registry_config" 0 bash "$PUSH" pacts-consumer-a "$T/pacts" abcdef1234
  logs "push_uses_registry_config: flag passed" "$FAKE_ORAS_LOG" "--registry-config $T/auth.json"
}
pull_other_error_fails() {
  reset; export FAKE_ORAS_BROKEN="pacts-consumer-a"
  run "pull_other_error_fails" 1 bash "$PULL" "$T/out" pacts-consumer-a pacts-consumer-b
  has "pull_other_error_fails: error shown" "connection refused"
}

# Mirrors the layout oras pull produces: <dir>/<package>/<file>.
gp_layout() {
  reset; rm -rf "${T:?}/gd" "${T:?}/build"
  mkdir -p "$T/gd/pact-results-provider-b" "$T/gd/pacts-consumer-a" "$T/build/pacts"
  cp "$G/base.json" "$T/gd/pacts-consumer-a/consumer-a-provider-b.json"
  cp "$G/new.json" "$T/build/pacts/consumer-a-provider-b.json"
}
gate_providers_reads_results_file() {
  gp_layout
  d1=$(digest_of "$G/new.json" "a request to delete a thing"); d2=$(digest_of "$G/new.json" "a request to create a thing")
  results "$T/gd/pact-results-provider-b/pact-results.json" "$d1:passed" "$d2:passed"
  run "gate_providers_reads_results_file" 0 gate_providers provider-b
  hasnt "gate_providers_reads_results_file: onboarded" "not onboarded"
}
gate_providers_fails_on_results() {
  gp_layout
  d1=$(digest_of "$G/new.json" "a request to delete a thing")
  results "$T/gd/pact-results-provider-b/pact-results.json" "$d1:passed"
  run "gate_providers_fails_on_results" 1 gate_providers provider-b
  has "gate_providers_fails_on_results: names it" "a request to create a thing"
}
gate_providers_no_results_is_notice() {
  gp_layout
  run "gate_providers_no_results_is_notice" 0 gate_providers provider-b
  has "gate_providers_no_results_is_notice: notice" "not onboarded"
}
gate_providers_no_base_pact_all_new() {
  gp_layout; rm "${T:?}/gd/pacts-consumer-a/consumer-a-provider-b.json"
  results "$T/gd/pact-results-provider-b/pact-results.json" "x:passed"
  run "gate_providers_no_base_pact_all_new" 1 gate_providers provider-b
}
gate_providers_skips_missing_pact() {
  gp_layout; rm "${T:?}/build/pacts/consumer-a-provider-b.json"
  run "gate_providers_skips_missing_pact" 0 gate_providers provider-b
  has "gate_providers_skips_missing_pact: notice" "::notice::"
}
gate_providers_one_failure_fails_all() {
  gp_layout; mkdir -p "$T/gd/pact-results-provider-c"
  cp "$G/new.json" "$T/build/pacts/consumer-a-provider-c.json"
  results "$T/gd/pact-results-provider-c/pact-results.json" "x:passed"
  run "gate_providers_one_failure_fails_all" 1 gate_providers provider-b provider-c
}
gate_providers_rejects_bad_name() {
  gp_layout
  run "gate_providers_rejects_bad_name" 2 gate_providers 'provider-b;x'
  has "gate_providers_rejects_bad_name: error" "::error::"
}

digest_ignores_description_and_metadata() {
  reset
  a=$(digest_of "$G/base.json" "a request for a thing"); b=$(digest_of "$G/meta-variant.json" "the same call")
  if [ -n "$a" ] && [ "$a" = "$b" ]; then pass "digest_ignores_description_and_metadata"; else fail "digest_ignores_description_and_metadata" "'$a' vs '$b'"; fi
  c=$(digest_of "$G/matcher-variant.json" "a request for a thing")
  if [ -n "$c" ] && [ "$a" != "$c" ]; then pass "digest_changes_with_matcher"; else fail "digest_changes_with_matcher" "'$a' vs '$c'"; fi
  run "digest_line_format" 0 bash "$DIGEST" "$G/base.json"
  if grep -qE '^[0-9a-f]{64}  a request for a thing$' <<<"$out"; then pass "digest_line_format: sha256, two spaces, description"; else fail "digest_line_format" "$out"; fi
}
gate_unchanged_passes() {
  reset
  results "$T/r.json" "x:passed"
  run "gate_unchanged_passes" 0 gate provider-b "$G/base.json" "$G/base.json" "$T/r.json"
  has "gate_unchanged_passes: warns" "::warning::"
  hasnt "gate_unchanged_passes: no error" "::error::"
}
gate_new_passed_passes() {
  reset
  d1=$(digest_of "$G/new.json" "a request to delete a thing"); d2=$(digest_of "$G/new.json" "a request to create a thing")
  results "$T/r.json" "$d1:passed" "$d2:passed"
  run "gate_new_passed_passes" 0 gate provider-b "$G/new.json" "$G/base.json" "$T/r.json"
  hasnt "gate_new_passed_passes: no error" "::error::"
}
gate_new_unverified_fails() {
  reset
  d1=$(digest_of "$G/new.json" "a request to delete a thing")
  results "$T/r.json" "$d1:passed"
  run "gate_new_unverified_fails" 1 gate provider-b "$G/new.json" "$G/base.json" "$T/r.json"
  has "gate_new_unverified_fails: names it" "a request to create a thing"
  has "gate_new_unverified_fails: design text" "has not verified this call yet"
  has "gate_new_unverified_fails: provider named" "provider-b's default branch"
  has "gate_new_unverified_fails: full text" "provider-b's default branch has not verified this call yet; release the provider change first, run provider-b's contract-results workflow (or wait for its daily run) and re-run this check, or move this interaction to the pending suite."
}
gate_changed_failed_fails() {
  reset
  d1=$(digest_of "$G/new.json" "a request to delete a thing"); d2=$(digest_of "$G/new.json" "a request to create a thing")
  results "$T/r.json" "$d1:failed" "$d2:passed"
  run "gate_changed_failed_fails" 1 gate provider-b "$G/new.json" "$G/base.json" "$T/r.json"
  has "gate_changed_failed_fails: names it" "a request to delete a thing"
}
gate_no_results_is_notice() {
  reset
  run "gate_no_results_is_notice" 0 gate provider-b "$G/new.json" "$G/base.json" ""
  has "gate_no_results_is_notice: notice" "not onboarded"
  run "gate_missing_results_file_is_notice" 0 gate provider-b "$G/new.json" "$G/base.json" "$T/nope.json"
  has "gate_missing_results_file_is_notice: notice" "not onboarded"
}
gate_no_base_pact_all_new() {
  reset
  results "$T/r.json" "x:passed"
  run "gate_no_base_pact_all_new" 1 gate provider-b "$G/base.json" "" "$T/r.json"
  has "gate_no_base_pact_all_new: error" "::error::"
}
gate_skips_non_default_base() {
  reset
  run "gate_skips_non_default_base" 0 env BASE_REF=demo DEFAULT_BRANCH=develop bash "$GATE" provider-b "$G/new.json" "$G/base.json" ""
  has "gate_skips_non_default_base: notice" "base demo is not the default branch; contract gate skipped"
}
gate_merge_group_base_ref() {
  reset
  run "gate_merge_group_base_ref" 0 env PR_BASE_REF= MERGE_GROUP_BASE_REF=refs/heads/develop bash "$BASEREF"
  if [ "$out" = develop ]; then pass "gate_merge_group_base_ref: develop"; else fail "gate_merge_group_base_ref" "got '$out'"; fi
  run "gate_pr_base_ref" 0 env PR_BASE_REF=develop MERGE_GROUP_BASE_REF= bash "$BASEREF"
  if [ "$out" = develop ]; then pass "gate_pr_base_ref: develop"; else fail "gate_pr_base_ref" "got '$out'"; fi
}

# results_layout <report-fixture> [source]: pacts-root/<source>/pacts-consumer-a/ with the 3-interaction pact,
# reports-dir/<source>/provider-b.json from the fixture.
results_layout() {
  local src=${2:-default}
  reset; rm -rf "${T:?}/pr" "${T:?}/rp"
  mkdir -p "$T/pr/$src/pacts-consumer-a" "$T/rp/$src"
  cp "$FIX/results/consumer-a-provider-b.json" "$T/pr/$src/pacts-consumer-a/"
  cp "$FIX/results/$1" "$T/rp/$src/provider-b.json"
}
# run_results <name> <want-exit> <args...>: results.sh; stdout (the JSON) in $out, stderr in $err.
run_results() {
  local name=$1 want=$2; shift 2
  out=$(bash "$RESULTS" "$@" 2>"$T/err"); code=$?; err=$(cat "$T/err")
  if [ "$code" = "$want" ]; then pass "$name"; else fail "$name" "exit $code want $want; output: $out $err"; fi
}
# stat_of <description>: status of that interaction in $out.
stat_of() { jq -r --arg d "$1" '.interactions[] | select(.description == $d) | .status' <<<"$out"; }
results_maps_report_to_digest() {
  results_layout report-pass-fail.json
  run_results "results_maps_report_to_digest" 0 provider-b "$T/pr" "$T/rp" abc1234def
  P=$FIX/results/consumer-a-provider-b.json
  if jq -e '.provider == "provider-b" and .sha == "abc1234def" and (.interactions | length) == 3' <<<"$out" >/dev/null; then pass "results_maps_report_to_digest: header and count"; else fail "results_maps_report_to_digest" "$out"; fi
  if [ "$(stat_of "a request for a thing")" = passed ] && [ "$(stat_of "a request to delete a thing")" = failed ]; then pass "results_maps_report_to_digest: statuses"; else fail "results_maps_report_to_digest: statuses" "$out"; fi
  d=$(digest_of "$P" "a request to delete a thing")
  if jq -e --arg d "$d" '.interactions[] | select(.description == "a request to delete a thing") | .digest == $d and .consumer == "consumer-a" and .source == "default"' <<<"$out" >/dev/null; then pass "results_maps_report_to_digest: digest, consumer, source"; else fail "results_maps_report_to_digest: digest" "$out"; fi
}
results_missing_from_report_fails_closed() {
  results_layout report-pass-fail.json
  run_results "results_missing_from_report_fails_closed" 0 provider-b "$T/pr" "$T/rp" abc1234
  if [ "$(stat_of "a request to create a thing")" = failed ]; then pass "results_missing_from_report_fails_closed: failed"; else fail "results_missing_from_report_fails_closed" "$out"; fi
  if [[ $err == *"::warning::"*"a request to create a thing"* ]]; then pass "results_missing_from_report_fails_closed: warning"; else fail "results_missing_from_report_fails_closed: warning" "$err"; fi
}
pr_failure_recorded_not_fatal() {
  results_layout report-all-failed.json pr-12
  run_results "pr_failure_recorded_not_fatal" 0 provider-b "$T/pr" "$T/rp" abc1234
  if jq -e '(.interactions | length) == 3 and all(.interactions[]; .status == "failed" and .source == "pr-12")' <<<"$out" >/dev/null; then pass "pr_failure_recorded_not_fatal: all failed from pr-12"; else fail "pr_failure_recorded_not_fatal" "$out"; fi
}
results_no_report_for_source_fails_closed() {
  results_layout report-pass-fail.json; rm -rf "${T:?}/rp/default"
  run_results "results_no_report_for_source_fails_closed" 0 provider-b "$T/pr" "$T/rp" abc1234
  if jq -e 'all(.interactions[]; .status == "failed")' <<<"$out" >/dev/null; then pass "results_no_report_for_source_fails_closed: failed"; else fail "results_no_report_for_source_fails_closed" "$out"; fi
}
results_ignores_other_providers_pacts() {
  results_layout report-pass-fail.json
  jq '.provider.name = "provider-z"' "$FIX/results/consumer-a-provider-b.json" > "$T/pr/default/pacts-consumer-a/consumer-a-provider-z.json"
  run_results "results_ignores_other_providers_pacts" 0 provider-b "$T/pr" "$T/rp" abc1234
  if jq -e '(.interactions | length) == 3' <<<"$out" >/dev/null; then pass "results_ignores_other_providers_pacts: only provider-b"; else fail "results_ignores_other_providers_pacts" "$out"; fi
}
results_rejects_bad_name() {
  results_layout report-pass-fail.json
  run_results "results_rejects_bad_name" 2 'provider-b;x' "$T/pr" "$T/rp" abc1234
  out=$err; has "results_rejects_bad_name: error" "::error::"
}
# tags_file <package> <tag> <days-old>...: write the fake registry's tag list.
tags_file() {
  local pkg=$1; shift; : > "$FAKE_ORAS_STORE/$pkg.tags"
  while [ $# -gt 0 ]; do printf '%s %s\n' "$1" "$(jq -rn --argjson d "$2" 'now - $d * 86400 | todate')" >> "$FAKE_ORAS_STORE/$pkg.tags"; shift 2; done
}
pull_pr_tags_age_filter() {
  reset; tags_file pacts-consumer-a default 1 pr-3 2 pr-9 20 other 1
  run "pull_pr_tags_age_filter" 0 bash "$PULL" --pr-tags 14 "$T/out" pacts-consumer-a
  logs "pull_pr_tags_age_filter: young pr tag pulled" "$FAKE_ORAS_LOG" "pacts-consumer-a:pr-3 -o $T/out/pr-3/pacts-consumer-a"
  nologs "pull_pr_tags_age_filter: old pr tag skipped" "$FAKE_ORAS_LOG" "pull ghcr.io/plantechhubdev/pacts-consumer-a:pr-9"
  nologs "pull_pr_tags_age_filter: non-pr tag skipped" "$FAKE_ORAS_LOG" "pull ghcr.io/plantechhubdev/pacts-consumer-a:other"
  logs "pull_pr_tags_age_filter: default pulled into default/" "$FAKE_ORAS_LOG" "pacts-consumer-a:default -o $T/out/default/pacts-consumer-a"
  exists "pull_pr_tags_age_filter: files land in pr dir" "$T/out/pr-3/pacts-consumer-a/consumer-a-provider-b.json"
}
pull_pr_tags_unlisted_package_is_notice() {
  reset
  run "pull_pr_tags_unlisted_package_is_notice" 0 bash "$PULL" --pr-tags 14 "$T/out" pacts-consumer-a
  has "pull_pr_tags_unlisted_package_is_notice: notice" "::notice::pacts-consumer-a pr tags not listable"
}
pull_pr_tags_rejects_bad_days() {
  reset
  run "pull_pr_tags_rejects_bad_days" 2 bash "$PULL" --pr-tags 'x' "$T/out" pacts-consumer-a
  has "pull_pr_tags_rejects_bad_days: error" "::error::"
}
push_explicit_tag() {
  reset; export EVENT_DEFAULT_BRANCH=develop GITHUB_REF_NAME=feature/x
  cp "$FIX/consumer-a-provider-b.json" "$T/pacts/"
  run "push_explicit_tag" 0 bash "$PUSH" --tag pr-7 pacts-consumer-a "$T/pacts" abcdef1234
  logs "push_explicit_tag: only the pr tag" "$FAKE_ORAS_LOG" "push ghcr.io/plantechhubdev/pacts-consumer-a:pr-7 "
  nologs "push_explicit_tag: no default tag" "$FAKE_ORAS_LOG" "default"
  nologs "push_explicit_tag: no sha tag" "$FAKE_ORAS_LOG" "sha-"
}
push_rejects_bad_tag() {
  reset; export EVENT_DEFAULT_BRANCH=develop GITHUB_REF_NAME=develop
  cp "$FIX/consumer-a-provider-b.json" "$T/pacts/"
  run "push_rejects_bad_tag" 2 bash "$PUSH" --tag 'pr-7,default' pacts-consumer-a "$T/pacts" abcdef1234
  has "push_rejects_bad_tag: error" "::error::"
  empty "push_rejects_bad_tag: no oras call" "$FAKE_ORAS_LOG"
}
results_null_description_does_not_crash() {
  results_layout report-pass-fail.json
  jq '.execution[0].interactions += [{"interaction": {}, "verification": {"result": "OK"}}]' "$FIX/results/report-pass-fail.json" > "$T/rp/default/provider-b.json"
  run_results "results_null_description_does_not_crash" 0 provider-b "$T/pr" "$T/rp" abc1234
  if [ "$(stat_of "a request for a thing")" = passed ] && [ "$(stat_of "a request to create a thing")" = failed ]; then pass "results_null_description_does_not_crash: statuses"; else fail "results_null_description_does_not_crash: statuses" "$out $err"; fi
}
results_skips_unknown_source_dirs() {
  results_layout report-pass-fail.json
  mkdir -p "$T/pr/scratch/pacts-consumer-a"; cp "$FIX/results/consumer-a-provider-b.json" "$T/pr/scratch/pacts-consumer-a/"
  run_results "results_skips_unknown_source_dirs" 0 provider-b "$T/pr" "$T/rp" abc1234
  if jq -e 'all(.interactions[]; .source == "default")' <<<"$out" >/dev/null; then pass "results_skips_unknown_source_dirs: only default"; else fail "results_skips_unknown_source_dirs" "$out"; fi
  if [[ $err == *"::warning::"*scratch* ]]; then pass "results_skips_unknown_source_dirs: warning"; else fail "results_skips_unknown_source_dirs: warning" "$err"; fi
}
pull_then_results_compose() {
  reset; tags_file pacts-consumer-a pr-12 2
  cp "$FIX/results/consumer-a-provider-b.json" "$T/store/pacts-consumer-a/"
  run "pull_then_results_compose: pull" 0 bash "$PULL" --pr-tags 14 "$T/out" pacts-consumer-a
  rm -rf "${T:?}/rp"; mkdir -p "$T/rp/default" "$T/rp/pr-12"
  cp "$FIX/results/report-pass-fail.json" "$T/rp/default/provider-b.json"
  cp "$FIX/results/report-all-failed.json" "$T/rp/pr-12/provider-b.json"
  run_results "pull_then_results_compose" 0 provider-b "$T/out" "$T/rp" abc1234
  if jq -e '(.interactions | length) == 6' <<<"$out" >/dev/null; then pass "pull_then_results_compose: both sources"; else fail "pull_then_results_compose: count" "$out $err"; fi
  d=$(jq -r '[.interactions[] | select(.source == "default" and .status == "passed")] | length' <<<"$out")
  f=$(jq -r '[.interactions[] | select(.source == "pr-12" and .status == "failed")] | length' <<<"$out")
  if [ "$d" = 1 ] && [ "$f" = 3 ]; then pass "pull_then_results_compose: statuses per source"; else fail "pull_then_results_compose: statuses" "default passed=$d pr-12 failed=$f"; fi
  case $err in *"No verification report"*) fail "pull_then_results_compose: no spurious warning" "$err" ;; *) pass "pull_then_results_compose: no spurious warning (stderr)" ;; esac
}
pull_pr_tags_manifest_not_found_is_notice() {
  reset; tags_file pacts-consumer-a pr-3 1
  FAKE_ORAS_MANIFEST_DENIED=1 run "pull_pr_tags_manifest_not_found_is_notice" 0 bash "$PULL" --pr-tags 14 "$T/out" pacts-consumer-a
  has "pull_pr_tags_manifest_not_found_is_notice: notice" "::notice::pacts-consumer-a:pr-3 manifest not readable"
}
push_rejects_non_pr_tags() {
  reset; export EVENT_DEFAULT_BRANCH=develop GITHUB_REF_NAME=feature/x
  cp "$FIX/consumer-a-provider-b.json" "$T/pacts/"
  for t in default sha-abcdef1 other; do
    run "push_rejects_non_pr_tags: $t" 2 bash "$PUSH" --tag "$t" pacts-consumer-a "$T/pacts" abcdef1234
  done
  empty "push_rejects_non_pr_tags: no oras call" "$FAKE_ORAS_LOG"
}
gate_malformed_new_pact_fails() {
  reset; printf '{not json' > "$T/bad.json"; results "$T/r.json" "x:passed"
  run "gate_malformed_new_pact_fails" 1 gate provider-b "$T/bad.json" "$G/base.json" "$T/r.json"
  has "gate_malformed_new_pact_fails: error" "::error::"
}
gate_empty_new_pact_fails() {
  reset; : > "$T/empty.json"; results "$T/r.json" "x:passed"
  run "gate_empty_new_pact_fails" 1 gate provider-b "$T/empty.json" "$G/base.json" "$T/r.json"
  has "gate_empty_new_pact_fails: error" "::error::"
}
gate_null_description_still_gated() {
  reset
  jq '.interactions = [{request: {method: "GET", path: "/a"}, response: {status: 200}}, {description: "a call nobody verified", request: {method: "GET", path: "/b"}, response: {status: 200}}]' "$G/base.json" > "$T/nodesc.json"
  d1=$(bash "$DIGEST" "$T/nodesc.json" | head -1 | cut -d' ' -f1)
  results "$T/r.json" "$d1:passed"
  run "gate_null_description_still_gated" 1 gate provider-b "$T/nodesc.json" "$G/base.json" "$T/r.json"
  has "gate_null_description_still_gated: names the unverified one" "a call nobody verified"
}
digest_null_description_and_bad_input() {
  reset
  jq '.interactions = [{request: {method: "GET", path: "/a"}, response: {status: 200}}]' "$G/base.json" > "$T/nodesc.json"
  run "digest_null_description" 0 bash "$DIGEST" "$T/nodesc.json"
  if grep -qE '^[0-9a-f]{64}  $' <<<"$out"; then pass "digest_null_description: empty description"; else fail "digest_null_description: line" "'$out'"; fi
  printf '{not json' > "$T/bad.json"; : > "$T/empty.json"; echo '{"interactions": 3}' > "$T/notarray.json"
  run "digest_rejects_malformed" 1 bash "$DIGEST" "$T/bad.json"
  run "digest_rejects_empty" 1 bash "$DIGEST" "$T/empty.json"
  run "digest_rejects_non_array" 1 bash "$DIGEST" "$T/notarray.json"
}
pull_command_not_found_fails() {
  reset; export FAKE_ORAS_CMDNOTFOUND="pacts-consumer-a"
  run "pull_command_not_found_fails" 1 bash "$PULL" "$T/out" pacts-consumer-a
  hasnt "pull_command_not_found_fails: not skipped" "not readable"
  has "pull_command_not_found_fails: error" "::error::"
}
# summary_layout <fetched-count> [verified-line...]: $T/sp/<package>/*.json pacts and $T/sum/summary.txt.
summary_layout() {
  reset; rm -rf "${T:?}/sp" "${T:?}/sum"; mkdir -p "$T/sp/pacts-consumer-a" "$T/sum"
  local n=$1 i; shift
  for ((i = 1; i <= n; i++)); do cp "$FIX/consumer-a-provider-b.json" "$T/sp/pacts-consumer-a/consumer-a-provider-b-$i.json"; done
  [ $# -eq 0 ] || printf '%s\n' "$@" > "$T/sum/summary.txt"
}
show_summary_prints_command_lines() {
  summary_layout 1 '::notice::verified 1 active pacts from consumer-a under default' 'plain log line'
  printf '::warning::pending pact failed: consumer-a\n::error::boom\n  ::notice::indented is not a command\n' > "$T/sum/pending-warnings.txt"
  echo '::notice::in a json file' > "$T/sum/ignored.json"
  run "show_summary_prints_command_lines" 0 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
  has "show_summary_prints_command_lines: notice" "::notice::verified 1 active pacts from consumer-a under default"
  has "show_summary_prints_command_lines: warning" "::warning::pending pact failed: consumer-a"
  has "show_summary_prints_command_lines: error" "::error::boom"
  hasnt "show_summary_prints_command_lines: non-command line ignored" "plain log line"
  hasnt "show_summary_prints_command_lines: indented ignored" "indented is not"
  hasnt "show_summary_prints_command_lines: only .txt files" "in a json file"
}
show_summary_verified_all_passes() {
  summary_layout 2 '::notice::verified 1 active pacts from consumer-a under default' '::notice::verified 1 active pacts from consumer-a under pr-3'
  run "show_summary_verified_all_passes" 0 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
}
show_summary_missing_summary_fails() {
  summary_layout 2
  run "show_summary_missing_summary_fails" 1 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
  has "show_summary_missing_summary_fails: message" "::error::fetched 2 consumer pacts from consumer-a but the build verified 0; the provider's contract test did not run or did not load them"
  has "show_summary_missing_summary_fails: notice" "::notice::no contract verification summary found under $T/sum"
}
show_summary_too_few_verified_fails() {
  summary_layout 2 '::notice::verified 1 active pacts from consumer-a under default'
  run "show_summary_too_few_verified_fails" 1 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
  has "show_summary_too_few_verified_fails: message" "::error::fetched 2 consumer pacts from consumer-a but the build verified 1;"
}
show_summary_missing_report_dir_fails() {
  summary_layout 1; rm -rf "${T:?}/sum"
  run "show_summary_missing_report_dir_fails" 1 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
  has "show_summary_missing_report_dir_fails: notice" "::notice::no contract verification summary found under $T/sum"
}
show_summary_nothing_fetched_is_notice() {
  summary_layout 0; rm -rf "${T:?}/sum"
  run "show_summary_nothing_fetched_is_notice" 0 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
  has "show_summary_nothing_fetched_is_notice: notice" "::notice::no consumer pacts were fetched"
  run "show_summary_missing_pacts_dir" 0 bash "$SUMMARY" "$T/sum" "$T/nope" provider-b
}
show_summary_pending_only_is_ok() {
  summary_layout 0; rm -rf "${T:?}/sum"
  jq '.consumer.name = "consumer-a.pending"' "$FIX/consumer-a-provider-b.json" > "$T/sp/pacts-consumer-a/consumer-a.pending-provider-b.json"
  run "show_summary_pending_only_is_ok" 0 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
  has "show_summary_pending_only_is_ok: nothing fetched" "::notice::no consumer pacts were fetched"
}
show_summary_counts_only_this_provider() {
  summary_layout 1 '::notice::verified 1 active pacts from consumer-a under default'
  jq '.provider.name = "provider-z"' "$FIX/consumer-a-provider-b.json" > "$T/sp/pacts-consumer-a/consumer-a-provider-z.json"
  run "show_summary_counts_only_this_provider" 0 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
}
show_summary_checks_each_consumer() {
  summary_layout 1 '::notice::verified 2 active pacts from consumer-a under default'
  mkdir -p "$T/sp/pacts-consumer-c"
  jq '.consumer.name = "consumer-c"' "$FIX/consumer-a-provider-b.json" > "$T/sp/pacts-consumer-c/consumer-c-provider-b.json"
  run "show_summary_checks_each_consumer" 1 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
  has "show_summary_checks_each_consumer: names the consumer" "consumer-c"
  has "show_summary_checks_each_consumer: error" "::error::fetched 1 consumer pacts from consumer-c but the build verified 0"
  printf '%s\n' '::notice::verified 1 active pacts from consumer-a under default' '::notice::verified 1 active pacts from consumer-a under pr-3' '::notice::verified 1 active pacts from consumer-c under default' > "$T/sum/summary.txt"
  run "show_summary_checks_each_consumer: duplicates sum per consumer" 0 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
}
show_summary_nested_source_layout() {
  reset; rm -rf "${T:?}/sp" "${T:?}/sum"; mkdir -p "$T/sp/default/pacts-consumer-a" "$T/sp/pr-3/pacts-consumer-a" "$T/sum"
  cp "$FIX/consumer-a-provider-b.json" "$T/sp/default/pacts-consumer-a/"; cp "$FIX/consumer-a-provider-b.json" "$T/sp/pr-3/pacts-consumer-a/"
  run "show_summary_nested_source_layout" 1 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
  has "show_summary_nested_source_layout: default unverified" "::error::fetched 1 consumer pacts from consumer-a under default but the build verified 0"
  has "show_summary_nested_source_layout: pr-3 unverified" "::error::fetched 1 consumer pacts from consumer-a under pr-3 but the build verified 0"
  echo '::notice::verified 2 active pacts from consumer-a under default' > "$T/sum/summary.txt"
  run "show_summary_nested_only_default_verified_fails_pr3" 1 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
  has "show_summary_nested_only_default_verified_fails_pr3: names pr-3" "under pr-3"
  hasnt "show_summary_nested_only_default_verified_fails_pr3: default fine" "under default but"
  printf '%s\n' "::notice::verified 1 active pacts from consumer-a under $T/sp/default" '::notice::verified 1 active pacts from consumer-a under pr-3' > "$T/sum/summary.txt"
  run "show_summary_nested_verified_ok (trailing folder component matches)" 0 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
}
show_summary_provider_name_mismatch_fails() {
  summary_layout 1 '::notice::verified 1 active pacts from consumer-a under default'
  run "show_summary_provider_name_mismatch_fails" 1 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b-service
  has "show_summary_provider_name_mismatch_fails: error" "::error::fetched 1 pacts but none for provider 'provider-b-service' (found: provider-b)"
}
show_summary_package_without_provider_warns() {
  summary_layout 1 '::notice::verified 1 active pacts from consumer-a under default'
  mkdir -p "$T/sp/pacts-consumer-d"
  jq '.provider.name = "provider-z" | .consumer.name = "consumer-d"' "$FIX/consumer-a-provider-b.json" > "$T/sp/pacts-consumer-d/consumer-d-provider-z.json"
  run "show_summary_package_without_provider_warns" 0 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
  has "show_summary_package_without_provider_warns: warning" "::warning::package pacts-consumer-d holds pacts but none for provider 'provider-b'"
  hasnt "show_summary_package_without_provider_warns: not the good package" "package pacts-consumer-a holds"
}
show_summary_large_n_compares_numerically() {
  summary_layout 2 '::notice::verified 999999 active pacts from consumer-a under default'
  run "show_summary_large_n_compares_numerically" 0 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
}
show_summary_odd_file_names() {
  summary_layout 0; rm -rf "${T:?}/sum"; mkdir -p "$T/sum" "$T/sp/pacts-consumer-a/sub dir"
  cp "$FIX/consumer-a-provider-b.json" "$T/sp/pacts-consumer-a/sub dir/a pact.json"
  run "show_summary_odd_file_names" 1 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
  has "show_summary_odd_file_names: counted" "::error::fetched 1 consumer pacts from consumer-a"
}
show_summary_rejects_bad_provider() {
  summary_layout 1 '::notice::verified 1 active pacts from consumer-a under default'
  run "show_summary_rejects_bad_provider" 2 bash "$SUMMARY" "$T/sum" "$T/sp" 'bad name;x'
  has "show_summary_rejects_bad_provider: error" "::error::"
  run "show_summary_rejects_empty_provider" 2 bash "$SUMMARY" "$T/sum" "$T/sp" ''
}
show_summary_skips_non_pact_json() {
  summary_layout 0; rm -rf "${T:?}/sum"
  echo '{"foo": 1}' > "$T/sp/pacts-consumer-a/other.json"; echo '[1,2]' > "$T/sp/pacts-consumer-a/list.json"; echo '{broken' > "$T/sp/pacts-consumer-a/broken.json"
  run "show_summary_skips_non_pact_json" 0 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
  has "show_summary_skips_non_pact_json: notice" "::notice::skipping non-pact JSON"
}
show_summary_bad_consumer_name_fails_closed() {
  summary_layout 0; rm -rf "${T:?}/sum"; mkdir -p "$T/sum"
  jq '.consumer.name = null' "$FIX/consumer-a-provider-b.json" > "$T/sp/pacts-consumer-a/x.json"
  run "show_summary_bad_consumer_name_fails_closed" 1 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
  echo '::notice::verified 5 active pacts from  under default' > "$T/sum/summary.txt"
  run "show_summary_bad_consumer_name_fails_closed: no line can cover it" 1 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
}
show_summary_caps_verified_digits() {
  summary_layout 1 '::notice::verified 99999999999 active pacts from consumer-a under default'
  run "show_summary_caps_verified_digits" 1 bash "$SUMMARY" "$T/sum" "$T/sp" provider-b
  has "show_summary_caps_verified_digits: error text" "the build may also have failed earlier"
}

default_branch_uses_event
default_branch_falls_back_to_api
default_branch_errors_when_unknown
push_on_default_branch
push_skips_non_default_branch
push_skips_empty_dir
pull_missing_package_is_notice
pull_denied_is_notice
pull_manifest_unknown_is_notice
pull_all_skipped_creates_out_dir
pull_uses_registry_config
pull_without_registry_config_omits_flag
pull_rejects_bad_package_name
push_uses_registry_config
pull_other_error_fails
digest_ignores_description_and_metadata
gate_unchanged_passes
gate_new_passed_passes
gate_new_unverified_fails
gate_changed_failed_fails
gate_no_results_is_notice
gate_no_base_pact_all_new
gate_skips_non_default_base
gate_merge_group_base_ref
gate_providers_reads_results_file
gate_providers_fails_on_results
gate_providers_no_results_is_notice
gate_providers_no_base_pact_all_new
gate_providers_skips_missing_pact
gate_providers_one_failure_fails_all
gate_providers_rejects_bad_name
results_maps_report_to_digest
results_missing_from_report_fails_closed
pr_failure_recorded_not_fatal
results_no_report_for_source_fails_closed
results_ignores_other_providers_pacts
results_rejects_bad_name
pull_pr_tags_age_filter
pull_pr_tags_unlisted_package_is_notice
pull_pr_tags_rejects_bad_days
push_explicit_tag
push_rejects_bad_tag
results_null_description_does_not_crash
results_skips_unknown_source_dirs
pull_then_results_compose
pull_pr_tags_manifest_not_found_is_notice
push_rejects_non_pr_tags
gate_malformed_new_pact_fails
gate_empty_new_pact_fails
gate_null_description_still_gated
digest_null_description_and_bad_input
pull_command_not_found_fails
show_summary_prints_command_lines
show_summary_verified_all_passes
show_summary_missing_summary_fails
show_summary_too_few_verified_fails
show_summary_missing_report_dir_fails
show_summary_nothing_fetched_is_notice
show_summary_pending_only_is_ok
show_summary_counts_only_this_provider
show_summary_checks_each_consumer
show_summary_nested_source_layout
show_summary_skips_non_pact_json
show_summary_bad_consumer_name_fails_closed
show_summary_caps_verified_digits
show_summary_provider_name_mismatch_fails
show_summary_package_without_provider_warns
show_summary_large_n_compares_numerically
show_summary_odd_file_names
show_summary_rejects_bad_provider
exit $status
