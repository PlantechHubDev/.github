#!/usr/bin/env bash
# Tests scripts/pact/{default-branch,oci-push,oci-pull}.sh with stub `oras` and `gh`
# (scripts/fixtures/pact/bin) first on PATH, so nothing touches GHCR or GitHub.
# Usage: bash scripts/test-pact.sh   (exit 0 when every case passes)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FIX=$HERE/fixtures/pact
export PATH="$FIX/bin:$PATH"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FAKE_ORAS_LOG=$T/oras.log FAKE_GH_LOG=$T/gh.log FAKE_ORAS_STORE=$T/store
export GITHUB_REPOSITORY=example-org/consumer-a
unset EVENT_DEFAULT_BRANCH FAKE_GH_DEFAULT_BRANCH FAKE_ORAS_NOT_FOUND FAKE_ORAS_UNKNOWN FAKE_ORAS_DENIED FAKE_ORAS_BROKEN GITHUB_REF_NAME ORAS_REGISTRY_CONFIG
status=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; status=1; }

reset() {
  : > "$FAKE_ORAS_LOG"; : > "$FAKE_GH_LOG"; rm -rf "$T/store" "$T/pacts" "$T/out"
  mkdir -p "$T/store/pacts-consumer-a" "$T/store/pacts-consumer-b" "$T/pacts"
  cp "$FIX/consumer-a-provider-b.json" "$T/store/pacts-consumer-a/"
  cp "$FIX/consumer-a-provider-b.json" "$T/store/pacts-consumer-b/"
  unset EVENT_DEFAULT_BRANCH FAKE_GH_DEFAULT_BRANCH FAKE_ORAS_NOT_FOUND FAKE_ORAS_UNKNOWN FAKE_ORAS_DENIED FAKE_ORAS_BROKEN GITHUB_REF_NAME ORAS_REGISTRY_CONFIG
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
exit $status
