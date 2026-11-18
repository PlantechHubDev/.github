#!/usr/bin/env bash
# deployed-sha.sh <service> <sha256:digest>: print the full 40-hex commit an ECR image was
# built from. The digest's ECR tags (repository <service>) must carry exactly one sha-<7> tag
# (the tag java-service-image.yml and java-service-publish.yml push); the short sha is then
# resolved in PlantechHubDev/<service> through `gh api .../commits/<sha7>`.
# Callers bring the digest from their own source (pth-sim.sh: the digest prod ECS is running).
#
# AWS: one read-only call with whatever AWS environment the caller sets (pth-sim.sh: the
# developer's SSO profile; a CI caller: its OIDC credentials). GitHub: gh, authenticated through
# GH_TOKEN or the developer's gh login.
#
# Exit: 0 prints the sha; 2 not resolvable (no or several sha- tags, image not found, commit
# lookup failed); 4 AWS auth failed (SSO expired or no credentials); 64 usage.
set -uo pipefail

ORG=PlantechHubDev
usage() { echo "deployed-sha: $1" >&2; echo "usage: deployed-sha.sh <service> <sha256:digest>" >&2; exit 64; }
die()   { echo "deployed-sha: $*" >&2; exit 2; }

[ $# -eq 2 ] || usage "expected 2 arguments, got $#"
svc=$1 digest=$2
[[ $svc =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage "bad service name '$svc'"
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || usage "digest must be sha256:<64 hex> (got '$digest')"

# The AWS CLI's wording when the SSO token has expired or no credentials can be found.
SSO_ERRORS='Token has expired|refresh failed|SSO session .*(expired|invalid)|sso.*(expired|invalid)|Unable to locate credentials|ExpiredToken|The config profile .* could not be found|Error loading SSO Token'

err=$(mktemp); trap 'rm -f "$err"' EXIT
if ! json=$(aws ecr describe-images --repository-name "$svc" --image-ids "imageDigest=$digest" --output json 2>"$err"); then
  if grep -Eqi -- "$SSO_ERRORS" "$err"; then
    echo "deployed-sha: SSO session expired: run aws sso login ${AWS_PROFILE:+--profile $AWS_PROFILE} ($(head -n 1 "$err"))" >&2
    exit 4
  fi
  die "cannot read $digest in ECR repository $svc: $(head -n 1 "$err")"
fi
tags=$(jq -r '.imageDetails[0].imageTags // [] | .[] | select(test("^sha-[0-9a-f]{7}$"))' <<<"$json" 2>/dev/null | sort -u)
n=$(printf '%s' "$tags" | grep -c . )
[ "$n" -ge 1 ] || die "no sha-<7> tag on $digest in $svc (tags: $(jq -r '.imageDetails[0].imageTags // [] | join(",")' <<<"$json" 2>/dev/null))"
[ "$n" -eq 1 ] || die "ambiguous: $digest in $svc has $n sha- tags ($(printf '%s' "$tags" | tr '\n' ' '))"
sha7=${tags#sha-}

sha=$(gh api "repos/$ORG/$svc/commits/$sha7" --jq .sha 2>"$err") \
  || die "cannot resolve $sha7 in $ORG/$svc: $(head -n 1 "$err")"
[[ $sha =~ ^[0-9a-f]{40}$ ]] || die "commit lookup of $sha7 in $ORG/$svc gave '$sha', not a 40-hex sha"
echo "$sha"
