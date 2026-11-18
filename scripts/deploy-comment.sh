#!/usr/bin/env bash
# deploy-comment.sh <merge-sha> <sha256:digest> <previous-digest> <run-url>: after a release
# deployed <digest> and the post-deploy checks passed, comment on each service PR the deploy
# carried, and repeat it in the step summary. The PRs are the "Merge pull request #N" commits on
# the first-parent history <previous deployed commit>..<merge-sha> of the service checkout. The
# previous deployed commit is the one <previous-digest> was built from (scripts/deployed-sha.sh);
# when it cannot be resolved, only the merge's own PR is commented on, with a ::warning::. A
# re-run on the same merge (previous digest = digest) has an empty range and comments on none.
#
# Environment:
#   SERVICE              the service (ECR repository) name (required)
#   GITHUB_REPOSITORY    <owner>/<repo> of the service, where the comments go (required)
#   SERVICE_REPO         a full-history checkout of the service (default: the current directory)
#   GH_TOKEN             the caller's GITHUB_TOKEN (pull-requests: write; contents: read)
#   GITHUB_STEP_SUMMARY  optional; the deployment and the PRs are added there
# AWS: one read-only ECR call (deployed-sha.sh), with the caller's credentials.
# Exit: 0 commented (or nothing to comment on); 1 git or gh failure; 64 usage.
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

deployed=""
if [ -n "$previous" ]; then
  deployed=$(bash "$HERE/deployed-sha.sh" "$SERVICE" "$previous" 2>/dev/null) || deployed=""
  [[ $deployed =~ ^[0-9a-f]{40}$ ]] && git -C "$repo_dir" rev-parse -q --verify "$deployed^{commit}" >/dev/null 2>&1 || deployed=""
fi
if [ -n "$deployed" ]; then
  subjects=$(git -C "$repo_dir" log --first-parent --reverse --format=%s "$deployed..$merge") \
    || { echo "::error::deploy-comment: cannot read $deployed..$merge" >&2; exit 1; }
  range="${deployed:0:7}..${merge:0:7}"
else
  echo "::warning::deploy-comment: the commit of the previous digest (${previous:-none}) is unknown; commenting only on the merge's own PR"
  subjects=$(git -C "$repo_dir" log -1 --format=%s "$merge")
  range="${merge:0:7}"
fi
prs=$(pr_numbers <<<"$subjects" | awk '!seen[$0]++')

body="Deployed to prod, and the deployment is stable (post-deploy checks passed).

- Image: \`$SERVICE@$digest\`
- Previous image: \`${previous:-unknown}\`
- Release run: $run"
summary "### Deployed $SERVICE@$digest (stable)"
summary ""
summary "- Previous image: \`${previous:-unknown}\`"
summary "- Release run: $run"
if [ -z "$prs" ]; then
  summary "- PRs: none in $range"
  echo "deploy-comment: no \"Merge pull request #N\" commit in $range; nothing to comment on" >&2
  exit 0
fi
rc=0
while IFS= read -r n; do
  if gh pr comment "$n" --repo "$GITHUB_REPOSITORY" --body "$body" >/dev/null; then
    summary "- PR #$n: commented"
  else
    echo "::error::deploy-comment: cannot comment on $GITHUB_REPOSITORY#$n" >&2
    summary "- PR #$n: comment failed"
    rc=1
  fi
done <<<"$prs"
exit "$rc"
