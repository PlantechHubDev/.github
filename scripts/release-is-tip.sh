#!/usr/bin/env bash
# release-is-tip.sh <owner/repo> <sha>: exit 0 only when <sha> is the current tip of master in
# <owner/repo>. java-service-release.yml runs it first, before any AWS step: re-running an old
# release run after newer merges would otherwise retag an old sha-<7> as :master and force a
# deployment of it, an unapproved rollback. A rollback goes through a revert PR in the merge
# queue, or a change record (or break-glass) for a manual retag.
#
# GitHub: gh, authenticated through GH_TOKEN (the caller's GITHUB_TOKEN, contents: read). No AWS.
# Usually exit 1 is benign: a newer merge landed first, and its release deploys this change too.
# Exit: 0 <sha> is the tip; 1 master has moved on (nothing may be retagged or deployed); 2 the
# tip could not be read; 64 usage.
set -uo pipefail
usage() { echo "release-is-tip: $1" >&2; echo "usage: release-is-tip.sh <owner/repo> <sha>" >&2; exit 64; }
[ $# -eq 2 ] || usage "expected 2 arguments, got $#"
repo=$1 sha=$2
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "bad repository '$repo'"
[[ $sha =~ ^[0-9a-f]{40}$ ]] || usage "sha must be 40 hex (got '$sha')"

tip=$(gh api "repos/$repo/commits/master" --jq .sha) \
  || { echo "::error::release-is-tip: cannot read the tip of master in $repo; nothing is retagged or deployed" >&2; exit 2; }
[[ $tip =~ ^[0-9a-f]{40}$ ]] || { echo "::error::release-is-tip: the tip of master in $repo reads as '$tip'; nothing is retagged or deployed" >&2; exit 2; }
if [ "$tip" != "$sha" ]; then
  echo "::error::release-is-tip: ${sha:0:7} is not released: master has moved on to ${tip:0:7}: a newer merge superseded this release, and its release deploys this change too. Nothing is retagged or deployed. If you meant to roll back, use a revert PR or a change record." >&2
  exit 1
fi
echo "release-is-tip: ${sha:0:7} is the tip of master" >&2
