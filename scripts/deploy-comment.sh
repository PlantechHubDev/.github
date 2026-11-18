#!/usr/bin/env bash
# deploy-comment.sh <merge-sha> <sha256:digest> <previous-digest|""> <run-url>: after a release
# deployed <digest> and the post-deploy checks passed, comment on each service PR the deploy
# carried (the change record), and repeat it in the step summary. The PRs are:
#   - always the merge's own PR(s): the "Merge pull request #N" subject of <merge-sha>, else
#     `gh api repos/<repo>/commits/<merge-sha>/pulls`;
#   - plus every "Merge pull request #N" on the first-parent history <start>..<merge-sha>, where
#     <start> is the head_sha of the newest successful push run of this release workflow on
#     master other than this run (GITHUB_RUN_ID). Runs blocked by the tip check or failed are
#     never successful, so a release that carries several merges, or a re-run, keeps every PR.
#     No earlier successful run (the first trunk deploy): the merge's own PR(s) only, with a
#     ::notice::. A lookup error, or a <start> not in the checkout or not an ancestor of
#     <merge-sha>, exits 1.
# <previous-digest> (what :master named before the retag) is only shown: "replaces <digest>", or
# "unknown (re-run)" when empty.
# Idempotent: each body carries the hidden marker <!-- pth-deploy:<sha7>:<digest> -->, and a PR
# that already has a comment with it is skipped, so re-runs never duplicate. No PR at all fails.
#
# Environment:
#   SERVICE              the service (ECR repository) name (required)
#   GITHUB_REPOSITORY    <owner>/<repo> of the service, where the comments go (required)
#   SERVICE_REPO         a full-history checkout of the service (default: the current directory)
#   GITHUB_RUN_ID        this run's id (required; excluded from the successful runs)
#   GH_TOKEN             the caller's GITHUB_TOKEN (pull-requests: write; contents: read; actions: read)
#   GITHUB_STEP_SUMMARY  optional; the deployment and the PRs are added there
# No AWS.
# Exit: 0 every PR has the comment (now or from an earlier run); 1 no PR found, or a git or gh
# failure; 64 usage.
set -uo pipefail
usage() { echo "deploy-comment: $1" >&2; echo "usage: deploy-comment.sh <merge-sha> <sha256:digest> <previous-digest> <run-url>" >&2; exit 64; }
[ $# -eq 4 ] || usage "expected 4 arguments, got $#"
merge=$1 digest=$2 previous=$3 run=$4
[[ $merge =~ ^[0-9a-f]{40}$ ]] || usage "merge-sha must be 40 hex (got '$merge')"
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || usage "digest must be sha256:<64 hex> (got '$digest')"
[[ $previous =~ ^(sha256:[0-9a-f]{64})?$ ]] || usage "previous-digest must be sha256:<64 hex> or empty (got '$previous')"
[[ $run =~ ^https://[^[:space:]]+$ ]] || usage "run-url must be an https URL (got '$run')"
[[ ${SERVICE:-} =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage "SERVICE must be the service name (got '${SERVICE:-}')"
[[ ${GITHUB_RUN_ID:-} =~ ^[0-9]+$ ]] || usage "GITHUB_RUN_ID must be this run's id (got '${GITHUB_RUN_ID:-}')"
[[ ${GITHUB_REPOSITORY:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "GITHUB_REPOSITORY must be <owner>/<repo> (got '${GITHUB_REPOSITORY:-}')"
repo_dir=${SERVICE_REPO:-.}
git -C "$repo_dir" rev-parse -q --verify "$merge^{commit}" >/dev/null 2>&1 || { echo "::error::deploy-comment: $merge is not in the service checkout $repo_dir" >&2; exit 1; }
summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "$*" >> "$GITHUB_STEP_SUMMARY"; }
pr_numbers() { sed -nE 's/^Merge pull request #([0-9]+)( .*)?$/\1/p'; }

# The merge's own PR(s): its "Merge pull request #N" subject, else the API's PRs for the commit.
own=$(git -C "$repo_dir" log -1 --format=%s "$merge" | pr_numbers)
if [ -z "$own" ]; then
  own=$(gh api "repos/$GITHUB_REPOSITORY/commits/$merge/pulls" | jq -r '.[]?.number // empty' 2>/dev/null) \
    || { echo "::error::deploy-comment: cannot list the PRs of ${merge:0:7}" >&2; exit 1; }
fi
# Plus every PR since the last successful release: the head_sha of the newest successful push
# run of this release workflow on master, other than this run. Blocked (tip check) and failed
# runs never count, so a re-run or a release that carries several merges keeps the right start.
die() { echo "::error::deploy-comment: $*" >&2; exit 1; }
wid=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" --jq .workflow_id) \
  || die "cannot read the workflow of run $GITHUB_RUN_ID; the PR range is unknown"
[[ $wid =~ ^[0-9]+$ ]] || die "the workflow of run $GITHUB_RUN_ID reads as '$wid'; the PR range is unknown"
runs=$(gh api "repos/$GITHUB_REPOSITORY/actions/workflows/$wid/runs?branch=master&event=push&status=success&per_page=100") \
  || die "cannot list the successful release runs; the PR range is unknown"
start=$(jq -r --arg me "$GITHUB_RUN_ID" '[.workflow_runs[] | select((.id | tostring) != $me)][0].head_sha // ""' <<<"$runs" 2>/dev/null) \
  || die "cannot read the successful release runs; the PR range is unknown"
inrange=""
if [ -z "$start" ]; then
  echo "::notice::deploy-comment: no earlier successful release of $SERVICE on master (the first trunk deploy): commenting on the merge's own PR only"
  range="${merge:0:7}"
else
  [[ $start =~ ^[0-9a-f]{40}$ ]] || die "the last successful release's commit reads as '$start'; the PR range is unknown"
  git -C "$repo_dir" rev-parse -q --verify "$start^{commit}" >/dev/null 2>&1 \
    || die "the last successful release's commit ${start:0:7} is not in the service checkout"
  git -C "$repo_dir" merge-base --is-ancestor "$start" "$merge" \
    || die "the last successful release's commit ${start:0:7} is not an ancestor of ${merge:0:7}"
  inrange=$(git -C "$repo_dir" log --first-parent --reverse --format=%s "$start..$merge" | pr_numbers) \
    || die "cannot read ${start:0:7}..${merge:0:7}"
  range="${start:0:7}..${merge:0:7}"
fi
prs=$(printf '%s\n%s\n' "$inrange" "$own" | awk 'NF && !seen[$0]++')
if [ -z "$prs" ]; then
  echo "::error::deploy-comment: no PR found for ${merge:0:7} (range $range): the deployment has no change record on a PR" >&2
  summary "### Deployed $SERVICE@$digest, but no PR found to comment on"
  exit 1
fi

if [ -n "$previous" ]; then prevtext="replaces \`$previous\`"; else prevtext="unknown (re-run)"; fi
# Hidden marker: a re-run finds it and does not comment twice.
marker="<!-- pth-deploy:${merge:0:7}:$digest -->"
body="Deployed to prod, and the deployment is stable (post-deploy checks passed).

- Image: \`$SERVICE@$digest\`
- Previous image: $prevtext
- Release run: $run

$marker"
summary "### Deployed $SERVICE@$digest (stable)"
summary ""
summary "- Previous image: $prevtext"
summary "- Release run: $run"
rc=0
while IFS= read -r n; do
  if ! existing=$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$n/comments"); then
    echo "::error::deploy-comment: cannot read the comments of $GITHUB_REPOSITORY#$n" >&2
    summary "- PR #$n: comments unreadable"
    rc=1; continue
  fi
  if jq -r '.[]?.body // empty' <<<"$existing" 2>/dev/null | grep -qF -- "$marker"; then
    echo "deploy-comment: #$n already has the deployment comment" >&2
    summary "- PR #$n: already commented"
    continue
  fi
  if gh pr comment "$n" --repo "$GITHUB_REPOSITORY" --body "$body" >/dev/null; then
    summary "- PR #$n: commented"
  else
    echo "::error::deploy-comment: cannot comment on $GITHUB_REPOSITORY#$n" >&2
    summary "- PR #$n: comment failed"
    rc=1
  fi
done <<<"$prs"
exit "$rc"
