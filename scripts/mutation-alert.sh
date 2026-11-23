#!/usr/bin/env bash
# mutation-alert.sh <owner/repo> <run-id> <run-url> <result>
#
# Run by mutation-nightly.yml's `alert` job after the `mutation` job, with that job's
# result (needs.mutation.result). A red nightly must reach someone (.github#33):
#   failure, cancelled  open one issue "mutation-nightly red: <repo>" (labels bug,
#                       area:test-infra, priority:P1) naming the failing step, the run
#                       link and the last 30 log lines of the mutation job; when that
#                       issue is already open, comment on it instead.
#   success             close the open issue, if any, with a link to the green run.
#   skipped             nothing.
# The log is best effort: when it cannot be read the issue still opens and says so.
# Needs GH_TOKEN with issues: write and actions: read. Exit 2: bad arguments.
set -euo pipefail

if [ $# -ne 4 ]; then
  echo "usage: mutation-alert.sh <owner/repo> <run-id> <run-url> <result>" >&2
  exit 2
fi
repo=$1 run_id=$2 run_url=$3 result=$4
case "$result" in
  success|failure|cancelled) ;;
  skipped) echo "mutation job skipped: nothing to report."; exit 0 ;;
  *) echo "unknown result '$result'" >&2; exit 2 ;;
esac

title="mutation-nightly red: ${repo#*/}"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

gh issue list --repo "$repo" --state open --label bug --limit 1000 --json number,title > "$tmp/open.json"
open=$(jq -r --arg t "$title" '[.[] | select(.title == $t)][0].number // empty' "$tmp/open.json")

if [ "$result" = success ]; then
  if [ -n "$open" ]; then
    gh issue close "$open" --repo "$repo" --comment "The nightly is green again: $run_url"
    echo "Closed #$open: $title"
  else
    echo "Green, and no open '$title' issue."
  fi
  exit 0
fi

# Red: name the failing step and quote the end of the mutation job's log.
step="unknown (see the run)"
job_id=""
if gh api "repos/$repo/actions/runs/$run_id/jobs?per_page=100" > "$tmp/jobs.json" 2>/dev/null; then
  job_id=$(jq -r '[.jobs[] | select(.name | test("(^|/ )mutation$")) | select(.conclusion != "success")][0].id // empty' "$tmp/jobs.json")
  if [ -n "$job_id" ]; then
    step=$(jq -r --argjson id "$job_id" '[.jobs[] | select(.id == $id) | .steps[] | select(.conclusion == "failure" or .conclusion == "cancelled") | .name][0] // "unknown (see the run)"' "$tmp/jobs.json")
  fi
fi
if [ -n "$job_id" ] && gh api "repos/$repo/actions/jobs/$job_id/logs" > "$tmp/job.log" 2>/dev/null && [ -s "$tmp/job.log" ]; then
  tail -n 30 "$tmp/job.log" | cut -c1-500 > "$tmp/tail.log"
else
  echo "(log unavailable: open the run)" > "$tmp/tail.log"
fi

{
  # shellcheck disable=SC2016  # backticks are markdown, not a command
  printf 'The nightly mutation run ended `%s`.\n\n' "$result"
  printf -- '- **Run:** %s\n' "$run_url"
  printf -- '- **Failing step:** %s\n\n' "$step"
  printf 'Last 30 lines of the mutation job log:\n\n~~~~text\n'
  cat "$tmp/tail.log"
  printf '~~~~\n\n'
  printf 'While the nightly is red the last tested commit does not move, so the next run covers a wider range. The next green run closes this issue.\n'
} > "$tmp/body.md"

if [ -n "$open" ]; then
  gh issue comment "$open" --repo "$repo" --body-file "$tmp/body.md"
  echo "Commented on #$open: $title"
else
  gh label create bug --repo "$repo" --color d73a4a --description "Something isn't working" >/dev/null 2>&1 || true
  gh label create area:test-infra --repo "$repo" --color 0E8A16 >/dev/null 2>&1 || true
  gh label create priority:P1 --repo "$repo" --color D93F0B >/dev/null 2>&1 || true
  gh issue create --repo "$repo" --title "$title" --label bug --label area:test-infra --label priority:P1 --body-file "$tmp/body.md"
fi
