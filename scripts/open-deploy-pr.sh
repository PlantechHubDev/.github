#!/usr/bin/env bash
# open-deploy-pr.sh <service> <sha256:digest> <merge-sha> <sim-run-url>
# open-deploy-pr.sh --base-digest <service>
# open-deploy-pr.sh --pins <service>
#
# Run in an infrastructure-live checkout (remote origin). Proposes the prod deploy of a released
# image: on branch deploy/<service>-<first 7 of merge-sha> it changes only the `image = "..."`
# line of plantechhub/us-east-1/prod/<service>/terragrunt.hcl to <registry>/<service>@<digest>
# (registry and repository taken from that line; indentation, alignment and any trailing comment
# kept), commits "deploy(<service>): pin <sha7>", pushes, and opens a PR into master titled
# "deploy(<service>): <sha7>". The body lists the service PRs ("Merge pull request #N" commits on
# the first-parent history <deployed>..<merge-sha>), the simulation link (or the text "simulation
# run: not found") and "Rollback digest: <digest master pins now>". Every other open PR whose head
# is deploy/<service>-<7 hex> in infrastructure-live itself (never a fork's) is closed with a
# comment naming the new PR.
# A re-run reuses the branch (adds a commit only if the pin differs; never force-pushes) and the
# open PR on it (body updated). If origin master already pins <digest>, it does nothing.
#
# --base-digest prints "<digest> <pin>" for what origin master pins now: "<digest> digest" for a
# digest pin, or "<tag's digest in ECR> tag:<tag>" for a tag pin (e.g. :master). Call it before any
# retag; pass the digest as BASE_DIGEST and the pin to release-image.sh (which then leaves a
# pinned :master alone).
#
# --pins prints "<path> <pin>" for every prod unit of the service on origin master, in every
# region (plantechhub/<region>/prod/<service>/terragrunt.hcl). <pin> is "digest", "tag:<name>", or
# "unparseable" when the unit has not exactly one image line of the form above. It reads git only
# (no AWS). release-image.sh reads this list and leaves :master alone while any unit pins :master
# or is unparseable (ECR replication would move :master in every region). Exit 0, or 2 when the
# service has no prod unit.
#
# Output: stdout carries only the PR URL (nothing when there is no PR); messages go to stderr.
# When GITHUB_STEP_SUMMARY is set, a line is added there: the PR, "already pinned", and any older
# deploy PR that could not be closed.
#
# Environment:
#   SERVICE_REPO      path to a full-history checkout of PlantechHubDev/<service> (required)
#   BASE_DIGEST       the rollback digest, required when master pins a tag rather than a digest
#   DEPLOY_GIT_NAME   commit identity: the CI App's bot, e.g. "<app-slug>[bot]"           (required
#   DEPLOY_GIT_EMAIL  "<bot user id>+<app-slug>[bot]@users.noreply.github.com"              unless DRY_RUN)
#   GITHUB_STEP_SUMMARY  optional; see Output above
#   GH_TOKEN          token for infrastructure-live (git fetch/push through gh's credential
#                     helper, PR list/create/edit/close): the CI App token
#   SERVICE_GH_TOKEN  token deployed-sha.sh uses to read the service's commits (default GH_TOKEN)
#   INFRA_REPO        default PlantechHubDev/infrastructure-live
#   DRY_RUN=1         print the branch, the file diff, the body and the PRs it would close; push,
#                     create, edit and close nothing (the working tree change is reverted)
# AWS (deployed-sha.sh, and --base-digest for a tag pin): read-only, the caller's credentials.
#
# Exit: 0 PR opened or updated (or already pinned; --base-digest: digest printed); 1 git, gh or
# aws failure (e.g. the branch cannot be pushed as a fast-forward); 2 the unit or its single
# image line is missing or not <registry>/<service>(:tag|@sha256:digest), or (--base-digest) the
# pinned tag is not in ECR; 64 usage.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ORG=PlantechHubDev
REPO=${INFRA_REPO:-$ORG/infrastructure-live}
NOT_FOUND="simulation run: not found"

usage() {
  echo "open-deploy-pr: $1" >&2
  echo "usage: open-deploy-pr.sh <service> <sha256:digest> <merge-sha> <sim-run-url>" >&2
  echo "       open-deploy-pr.sh --base-digest <service>" >&2
  echo "       open-deploy-pr.sh --pins <service>" >&2
  exit 64
}
die()  { echo "open-deploy-pr: $*" >&2; exit 1; }
die2() { echo "open-deploy-pr: $*" >&2; exit 2; }
summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "$*" >> "$GITHUB_STEP_SUMMARY"; }
# Network git: credentials from gh (GH_TOKEN), since the checkout keeps none.
Gn() { git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"; }

base_mode=false pins_mode=false
if [ "${1-}" = --base-digest ] || [ "${1-}" = --pins ]; then
  if [ "$1" = --pins ]; then pins_mode=true; else base_mode=true; fi
  [ $# -eq 2 ] || usage "$1 takes 1 argument, got $(($# - 1))"
  svc=$2
else
  [ $# -eq 4 ] || usage "expected 4 arguments, got $#"
  svc=$1 digest=$2 merge=$3 sim=$4
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || usage "digest must be sha256:<64 hex> (got '$digest')"
  [[ $merge =~ ^[0-9a-f]{40}$ ]] || usage "merge-sha must be 40 hex (got '$merge')"
  [ -n "$sim" ] || usage "sim-run-url is empty (pass the run URL or '$NOT_FOUND')"
  if [ "${DRY_RUN:-}" != 1 ]; then
    { [ -n "${DEPLOY_GIT_NAME:-}" ] && [ -n "${DEPLOY_GIT_EMAIL:-}" ]; } || usage "DEPLOY_GIT_NAME and DEPLOY_GIT_EMAIL (the CI App's bot identity) must be set"
  fi
  { [ -n "${SERVICE_REPO:-}" ] && git -C "$SERVICE_REPO" rev-parse --git-dir >/dev/null 2>&1; } \
    || usage "SERVICE_REPO must be a checkout of $ORG/$svc (got '${SERVICE_REPO:-}')"
fi
[[ $svc =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage "bad service name '$svc'"
UNIT=plantechhub/us-east-1/prod/$svc/terragrunt.hcl

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# parse_pin <file> [label]: find (messages name <label>, default the unit path) the one `image =` line and split it. Sets PIN_NO (line number), PIN_PRE
# (up to the opening quote), PIN_VAL, PIN_POST (closing quote on), PIN_IMAGE (<registry>/<service>),
# and PIN_TAG or PIN_DIGEST. Exits 2 when there is not exactly one such line or it does not parse.
parse_pin() {
  local hits count line re label=${2:-$UNIT}
  hits=$(grep -nE '^[[:space:]]*image[[:space:]]*=' "$1")
  count=$(printf '%s' "$hits" | grep -c .)
  [ "$count" -eq 1 ] || die2 "$label: expected exactly one 'image =' line, found $count"
  PIN_NO=${hits%%:*} line=${hits#*:}
  re='^([[:space:]]*image[[:space:]]*=[[:space:]]*")([^"]*)(".*)$'
  [[ $line =~ $re ]] || die2 "$label:$PIN_NO: image is not a quoted string: $line"
  PIN_PRE=${BASH_REMATCH[1]} PIN_VAL=${BASH_REMATCH[2]} PIN_POST=${BASH_REMATCH[3]}
  re="^([^\"@[:space:]]+/$svc)(:([A-Za-z0-9_][A-Za-z0-9_.-]*)|@(sha256:[0-9a-f]{64}))\$"
  [[ $PIN_VAL =~ $re ]] || die2 "$label:$PIN_NO: image '$PIN_VAL' is not <registry>/$svc:<tag> or <registry>/$svc@sha256:<digest>"
  PIN_IMAGE=${BASH_REMATCH[1]} PIN_TAG=${BASH_REMATCH[3]} PIN_DIGEST=${BASH_REMATCH[4]}
}

# What origin master pins now.
Gn fetch -q origin master 2>"$tmp/err" || die "cannot fetch origin master: $(head -n 1 "$tmp/err")"

if $pins_mode; then
  units=$(git ls-tree -r --name-only origin/master -- plantechhub | grep -E "^plantechhub/[^/]+/prod/$svc/terragrunt\.hcl\$")
  [ -n "$units" ] || die2 "no prod unit plantechhub/<region>/prod/$svc/terragrunt.hcl on origin master"
  while IFS= read -r u; do
    # parse_pin exits on a bad unit; the subshell turns that into "unparseable" (fail closed).
    pin=$(git show "origin/master:$u" > "$tmp/u.hcl" 2>/dev/null &&
          parse_pin "$tmp/u.hcl" "$u" 2>/dev/null &&
          if [ -n "$PIN_DIGEST" ]; then echo digest; else echo "tag:$PIN_TAG"; fi) || pin=unparseable
    echo "$u $pin"
  done <<<"$units"
  exit 0
fi
git show "origin/master:$UNIT" > "$tmp/master.hcl" 2>/dev/null || die2 "$UNIT not found on origin master"
parse_pin "$tmp/master.hcl"

if $base_mode; then
  if [ -n "$PIN_DIGEST" ]; then echo "$PIN_DIGEST digest"; exit 0; fi
  d=$(bash "$HERE/ecr-existing-digest.sh" "$svc" "$PIN_TAG") || die "cannot read $svc:$PIN_TAG in ECR"
  [ -n "$d" ] || die2 "$svc:$PIN_TAG (pinned on master) is not in ECR"
  echo "$d tag:$PIN_TAG"; exit 0
fi

sha7=${merge:0:7}
BR=deploy/$svc-$sha7
TITLE="deploy($svc): $sha7"
new_val=$PIN_IMAGE@$digest
if [ "$PIN_VAL" = "$new_val" ]; then
  echo "open-deploy-pr: origin master already pinned to $new_val; nothing to deploy" >&2
  summary "$svc $sha7: infrastructure-live master is already pinned to $digest; no deploy PR."
  exit 0
fi
if [ -n "$PIN_DIGEST" ]; then
  base=$PIN_DIGEST
elif [[ ${BASE_DIGEST:-} =~ ^sha256:[0-9a-f]{64}$ ]]; then
  base=$BASE_DIGEST
else
  usage "master pins the tag '$PIN_TAG', so BASE_DIGEST (its digest, read before the retag) must be set (got '${BASE_DIGEST:-}')"
fi
# A tag pin read after the retag already moved the tag (a re-run) names the new image itself.
[ "$base" != "$digest" ] || die "the rollback digest is the new image ($digest): master pins :$PIN_TAG, which already moved to it; set BASE_DIGEST to the digest prod ran before and re-run"

# --- The service PRs this deploy carries.
prs=""
if [ -n "${SERVICE_GH_TOKEN:-}" ]; then
  deployed=$(GH_TOKEN=$SERVICE_GH_TOKEN bash "$HERE/deployed-sha.sh" "$svc" "$base" 2>"$tmp/err")
else
  deployed=$(bash "$HERE/deployed-sha.sh" "$svc" "$base" 2>"$tmp/err")
fi
if [ -z "$deployed" ]; then
  prs="- could not list: the deployed commit of $base is unknown ($(head -n 1 "$tmp/err"))"
elif ! subjects=$(git -C "$SERVICE_REPO" log --first-parent --reverse --format=%s "$deployed..$merge" 2>"$tmp/err"); then
  prs="- could not list: no history $deployed..$merge in the service checkout ($(head -n 1 "$tmp/err"))"
else
  while IFS= read -r n; do
    [ -n "$n" ] && prs="$prs- $ORG/$svc#$n"$'\n'
  done < <(printf '%s\n' "$subjects" | sed -nE 's/^Merge pull request #([0-9]+)( .*)?$/\1/p')
  [ -n "$prs" ] || prs="- none found (no \"Merge pull request #N\" commits in ${deployed:0:7}..$sha7)"
fi

body=$tmp/body.md
{
  echo "Deploy $svc $sha7 to prod: the image the merge queue built and simulated, retagged as master (not rebuilt)."
  echo
  echo "- Image: \`$new_val\`"
  echo "- Commit: https://github.com/$ORG/$svc/commit/$merge"
  if [ "$sim" = "$NOT_FOUND" ]; then echo "- Simulation: $NOT_FOUND"; else echo "- Simulation: $sim"; fi
  echo
  echo "Rollback digest: $base"
  echo
  echo "## Service PRs (${deployed:0:7}..$sha7)"
  echo
  printf '%s\n' "${prs%$'\n'}"
} > "$body"

# --- The branch: reuse it if it exists (a re-run), else start it from origin/master.
Gn ls-remote --exit-code --heads origin "refs/heads/$BR" >/dev/null 2>"$tmp/err"; rc=$?
case $rc in
  0) Gn fetch -q origin "+refs/heads/$BR:refs/remotes/origin/$BR" 2>"$tmp/err" || die "cannot fetch $BR: $(head -n 1 "$tmp/err")"
     git checkout -q -B "$BR" "origin/$BR" || die "cannot check out $BR"
     existed=true ;;
  2) git checkout -q -B "$BR" origin/master || die "cannot create $BR from origin/master"
     existed=false ;;
  *) die "cannot read origin's branches: $(head -n 1 "$tmp/err")" ;;
esac

# Change only the image line.
[ -f "$UNIT" ] || die2 "$UNIT not found on $BR"
parse_pin "$UNIT"
{
  [ "$PIN_NO" -gt 1 ] && head -n $((PIN_NO - 1)) "$UNIT"
  printf '%s%s%s\n' "$PIN_PRE" "$PIN_IMAGE@$digest" "$PIN_POST"
  tail -n +$((PIN_NO + 1)) "$UNIT"
} > "$tmp/unit.hcl"
cat "$tmp/unit.hcl" > "$UNIT"
changed=true
git diff --quiet -- "$UNIT" && changed=false

# Only PRs whose head branch lives in infrastructure-live itself; a fork's PR is never ours.
open=$(gh pr list -R "$REPO" --state open --limit 200 --json number,headRefName,url,isCrossRepository,headRepositoryOwner) || die "cannot list open PRs in $REPO"
open=$(jq --arg o "${REPO%%/*}" '[.[] | select((.isCrossRepository // false) == false and ((.headRepositoryOwner.login // $o) == $o))]' <<<"$open") || die "cannot read the open PR list"
own=$(jq -r --arg b "$BR" '[.[] | select(.headRefName == $b)][0] | if . then "\(.number) \(.url)" else empty end' <<<"$open") || die "cannot read the open PR list"
older=$(jq -r --arg b "$BR" --arg re "^deploy/$svc-[0-9a-f]{7}\$" '.[] | select((.headRefName | test($re)) and .headRefName != $b) | .number' <<<"$open") || die "cannot read the open PR list"

if [ "${DRY_RUN:-}" = 1 ]; then
  exec >&2   # stdout carries only a PR URL, and a dry run opens none
  echo "DRY RUN: nothing is pushed, created, edited or closed"
  echo "branch: $BR ($(if $existed; then echo exists on origin; else echo new from origin/master; fi))"
  echo "--- diff"
  git --no-pager diff -- "$UNIT"
  echo "--- PR: $(if [ -n "$own" ]; then echo "update #${own%% *}"; else echo create; fi) into master: $TITLE"
  cat "$body"
  echo "---"
  for n in $older; do echo "would close #$n"; done
  git checkout -q -- "$UNIT"
  exit 0
fi

if $changed; then
  GIT_AUTHOR_NAME=$DEPLOY_GIT_NAME GIT_AUTHOR_EMAIL=$DEPLOY_GIT_EMAIL \
  GIT_COMMITTER_NAME=$DEPLOY_GIT_NAME GIT_COMMITTER_EMAIL=$DEPLOY_GIT_EMAIL \
    git -c commit.gpgsign=false commit -q --no-verify -m "deploy($svc): pin $sha7" -- "$UNIT" \
    || die "cannot commit $UNIT"
fi
if $changed || ! $existed; then
  Gn push -q origin "HEAD:refs/heads/$BR" 2>"$tmp/err" \
    || die "cannot push $BR: it is never force-pushed, so if origin's $BR moved, delete it or bring it up to date by hand and re-run ($(head -n 1 "$tmp/err"))"
fi

if [ -n "$own" ]; then
  url=${own#* }
  gh pr edit "${own%% *}" -R "$REPO" --title "$TITLE" --body-file "$body" >/dev/null || die "cannot update PR $url"
else
  url=$(gh pr create -R "$REPO" --base master --head "$BR" --title "$TITLE" --body-file "$body") || die "cannot create the PR for $BR"
fi

summary "Deploy PR for $svc $sha7: $url"
failed=0
for n in $older; do
  if ! gh pr close "$n" -R "$REPO" --comment "Superseded by $url" >/dev/null; then
    echo "open-deploy-pr: cannot close older deploy PR #$n" >&2
    summary "The deploy PR $url is open, but the older deploy PR #$n in $REPO could not be closed: close it by hand."
    failed=1
  fi
done
echo "$url"
exit $failed
