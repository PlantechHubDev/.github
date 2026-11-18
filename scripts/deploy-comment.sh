#!/usr/bin/env bash
# deploy-comment.sh <merge-sha> <sha256:digest> <previous-digest|""> <run-url>: after a release
# deployed <digest> and the post-deploy checks passed, comment on each service PR the deploy
# carried (the change record), and repeat it in the step summary. The PRs are:
#   - always the merge's own PR(s): the "Merge pull request #N" subject of <merge-sha>, else
#     `gh api repos/<repo>/commits/<merge-sha>/pulls`;
#   - plus, when <previous-digest> (what :master named before the retag) resolves to a commit
#     (scripts/deployed-sha.sh), every "Merge pull request #N" on the first-parent history
#     <previous commit>..<merge-sha>. An empty <previous-digest> (no :master before, or a re-run)
#     or an unresolvable one leaves only the merge's own PR(s), the latter with a ::warning::.
# Idempotent: each body carries the hidden marker <!-- pth-deploy:<sha7>:<digest> -->, and a PR
# that already has a comment with it is skipped, so re-runs never duplicate. No PR at all fails.
#
# Environment:
#   SERVICE              the service (ECR repository) name (required)
#   GITHUB_REPOSITORY    <owner>/<repo> of the service, where the comments go (required)
#   SERVICE_REPO         a full-history checkout of the service (default: the current directory)
#   GH_TOKEN             the caller's GITHUB_TOKEN (pull-requests: write; contents: read)
#   GITHUB_STEP_SUMMARY  optional; the deployment and the PRs are added there
# AWS: one read-only ECR call (deployed-sha.sh), with the caller's credentials.
# Exit: 0 every PR has the comment (now or from an earlier run); 1 no PR found, or a git or gh
# failure; 64 usage.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
usage() { echo "deploy-comment: $1" >&2; echo "usage: deploy-comment.sh <merge-sha> <sha256:digest> <previous-digest> <run-url>" >&2; exit 64; }
[ $# -eq 4 ] || usage "expected 4 arguments, got $#"
merge=$1 digest=$2 previous=$3 run=$4
[[ $merge =~ ^[0-9a-f]{40}$ ]] || usage "merge-sha must be 40 hex (got '$merge')"
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || usage "digest must be sha256:<64 hex> (got '$digest')"
[[ $previous =~ ^(sha256:[0-9a-f]{64})?$ ]] || usage "previous-digest must be sha256:<64 hex> or empty (got '$previous')"
[[ $run =~ ^https://[^[:space:]]+$ ]] || usage "run-url must be an https URL (got '$run')"
[[ ${SERVICE:-} =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage "SERVICE must be the service name (got '${SERVICE:-}')"
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
# Plus every PR in <previous deployed commit>..<merge-sha>, when the previous commit is known.
deployed="" range=""
if [ -n "$previous" ]; then
  deployed=$(bash "$HERE/deployed-sha.sh" "$SERVICE" "$previous" 2>/dev/null) || deployed=""
  [[ $deployed =~ ^[0-9a-f]{40}$ ]] && git -C "$repo_dir" rev-parse -q --verify "$deployed^{commit}" >/dev/null 2>&1 || deployed=""
  [ -n "$deployed" ] || echo "::warning::deploy-comment: the commit of the previous digest $previous is unknown; commenting on the merge's own PR only"
fi
if [ -n "$deployed" ]; then
  inrange=$(git -C "$repo_dir" log --first-parent --reverse --format=%s "$deployed..$merge" | pr_numbers) \
    || { echo "::error::deploy-comment: cannot read $deployed..$merge" >&2; exit 1; }
  range="${deployed:0:7}..${merge:0:7}"
else
  inrange="" range="${merge:0:7}"
fi
prs=$(printf '%s\n%s\n' "$inrange" "$own" | awk 'NF && !seen[$0]++')
if [ -z "$prs" ]; then
  echo "::error::deploy-comment: no PR found for ${merge:0:7} (range $range): the deployment has no change record on a PR" >&2
  summary "### Deployed $SERVICE@$digest, but no PR found to comment on"
  exit 1
fi

# Hidden marker: a re-run finds it and does not comment twice.
marker="<!-- pth-deploy:${merge:0:7}:$digest -->"
body="Deployed to prod, and the deployment is stable (post-deploy checks passed).

- Image: \`$SERVICE@$digest\`
- Previous image: \`${previous:-unknown}\`
- Release run: $run

$marker"
summary "### Deployed $SERVICE@$digest (stable)"
summary ""
summary "- Previous image: \`${previous:-unknown}\`"
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
