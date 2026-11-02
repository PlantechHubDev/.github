#!/usr/bin/env bash
# paired-tests-check.sh: check a PR's pasted platform-tests evidence against its pairing.
#
# Usage:
#   paired-tests-check.sh <repo> <pr-number>          the check
#   paired-tests-check.sh --gate <repo> <pr-number>   only decide whether the check needs a
#                                                     token: writes needed=true|false to
#                                                     $GITHUB_OUTPUT (stdout when unset)
# <repo> is the repo name in PlantechHubDev, with or without the "PlantechHubDev/" prefix.
#
# The PR (body, head ref and sha, base ref and sha) is always read from the API, never from
# an event payload, because a re-run replays the original payload.
# The expected platform-tests commit comes from the handbook's pt-ref ($PT_REF, default
# "pt-ref" on PATH): release mode (--release <baseSha>..<headSha>) when the base is master or
# main, else the head ref. The PR body's line is parsed by parse-pt-line.sh (same directory).
#
#   Paired (source is not master)  the body MUST carry the line, and its sha MUST equal the
#                                  paired platform-tests PR's current head.
#   Unpaired (source is master)    no line passes; a line MUST name a commit in
#                                  platform-tests master's history (any age).
#   No issue number in the head ref, base not master/main, and no line (Dependabot and other
#   secret-less PRs): passes without calling pt-ref, and --gate says needed=false.
#
# Exit: 0 pass, 1 mismatch (or missing / duplicate line), 2 resolver or API error, 64 usage.
# Needs gh and jq; gh authenticates through GH_TOKEN.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ORG=PlantechHubDev
PT_REF=${PT_REF:-pt-ref}

usage() { echo "usage: paired-tests-check.sh [--gate] <repo> <pr-number>" >&2; exit 64; }

# annotate <error|notice> <message>: a GitHub Actions annotation (multi-line safe).
annotate() {
  local m=$2
  m=${m//'%'/%25}; m=${m//$'\r'/%0D}; m=${m//$'\n'/%0A}
  echo "::$1::$m"
}
pass()      { annotate notice "paired-tests: $1"; exit 0; }
mismatch()  { annotate error "paired-tests: $1"; exit 1; }
api_error() { annotate error "paired-tests: $1"; exit 2; }

gate=false
if [ "${1:-}" = "--gate" ]; then gate=true; shift; fi
[ $# -eq 2 ] || usage
repo=${1#"$ORG"/}
pr=$2
[[ $repo =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage
[[ $pr =~ ^[0-9]+$ ]] || usage

err=$(mktemp); trap 'rm -f "$err"' EXIT
fields=$(gh api "repos/$ORG/$repo/pulls/$pr" \
  --jq '{body: (.body // ""), headRef: .head.ref, headSha: .head.sha, base: .base.ref, baseSha: .base.sha}' 2>"$err") \
  || api_error "cannot read $ORG/$repo#$pr from the API: $(cat "$err")"
field() { jq -r --arg k "$1" '.[$k] // ""' <<<"$fields"; }
body=$(field body); head_ref=$(field headRef); head_sha=$(field headSha)
base=$(field base); base_sha=$(field baseSha)
[ -n "$head_ref" ] && [ -n "$head_sha" ] && [ -n "$base" ] && [ -n "$base_sha" ] \
  || api_error "incomplete pull request data for $ORG/$repo#$pr"

found=$(printf '%s' "$body" | bash "$HERE/parse-pt-line.sh" 2>/dev/null); parse_rc=$?

release=false
case "$base" in master | main) release=true ;; esac
has_issue=false
[[ $head_ref =~ ^[a-z]+/([0-9]+)- ]] && has_issue=true

# Nothing to resolve: no issue number, not a release, and no line (exit 3 counts as a line).
if [ "$has_issue" = false ] && [ "$release" = false ] && [ "$parse_rc" -eq 0 ] && [ -z "$found" ]; then
  if [ "$gate" = true ]; then echo "needed=false" >>"${GITHUB_OUTPUT:-/dev/stdout}"; fi
  pass "head '$head_ref' has no issue number and the PR body has no platform-tests line: nothing to check (unpaired)"
fi
if [ "$gate" = true ]; then
  echo "needed=true" >>"${GITHUB_OUTPUT:-/dev/stdout}"
  exit 0
fi

if [ "$parse_rc" -eq 3 ]; then
  mismatch "more than one platform-tests line in the PR body, with different shas; keep only the current platform-tests summary"
elif [ "$parse_rc" -ne 0 ]; then
  api_error "cannot parse the PR body (parse-pt-line.sh exit $parse_rc)"
fi

if [ "$release" = true ]; then
  args=("$repo" --release "$base_sha..$head_sha")
else
  args=("$repo" "$head_ref")
fi
resolved=$("$PT_REF" "${args[@]}" 2>"$err"); rc=$?
if [ "$rc" -ne 0 ]; then
  api_error "cannot resolve the paired platform-tests commit (pt-ref ${args[*]}, exit $rc): $(cat "$err")"
fi
read -r want_sha source <<<"$resolved"
[[ ${want_sha:-} =~ ^[0-9a-f]{40}$ ]] && [ -n "${source:-}" ] \
  || api_error "pt-ref ${args[*]} printed '$resolved', not '<sha> <source>'"
expected="platform-tests: $want_sha $source"

if [ "$source" = master ]; then
  [ -n "$found" ] || pass "unpaired (platform-tests master) and the PR body has no platform-tests line: nothing to check"
  status=$(gh api "repos/$ORG/platform-tests/compare/$found...master" --jq .status 2>"$err"); crc=$?
  if [ "$crc" -ne 0 ]; then
    mismatch "the PR body names platform-tests $found, an unknown commit (compare with master failed: $(cat "$err")); unpaired PRs need a commit in platform-tests master's history, e.g. $expected"
  fi
  case "$status" in
    ahead | identical) pass "unpaired; platform-tests $found is in master's history" ;;
    *) mismatch "the PR body names platform-tests $found, which is not in platform-tests master's history (compare status '$status'); unpaired PRs need a commit on master, e.g. $expected" ;;
  esac
fi

[ -n "$found" ] \
  || mismatch "paired with $source and the PR body has no platform-tests line: paste the platform-tests summary (cmd:pt-verify) into the PR body; expected $expected"
[ "$found" = "$want_sha" ] \
  || mismatch "the PR body names platform-tests $found, but the paired head is $want_sha ($source); re-run cmd:pt-verify against it and paste the new summary; expected $expected"
pass "paired with $source; the PR body names the current paired head $want_sha"
