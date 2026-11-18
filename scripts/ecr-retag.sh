#!/usr/bin/env bash
# ecr-retag.sh <service> <from-tag> <to-tag>: give the image <service>:<from-tag> the tag <to-tag>
# too, by copying its manifest (aws ecr batch-get-image + put-image), and print its digest.
# Nothing is pulled, built or pushed: the image under <to-tag> is byte-for-byte the one that was
# tested. A multi-arch image keeps its index (the accepted media types stop ECR converting it).
# java-service-release.yml uses it to retag the simulated queue image sha-<7> as master.
#
# AWS: whatever credentials the caller set (the release workflow: OIDC role-to-assume).
# Exit: 0 prints the digest (also when <to-tag> already points at it: a re-run); 1 aws failure
# (including an immutable <to-tag> that points elsewhere); 2 <from-tag> not in ECR (never
# rebuilt); 64 usage.
set -uo pipefail

usage() { echo "ecr-retag: $1" >&2; echo "usage: ecr-retag.sh <service> <from-tag> <to-tag>" >&2; exit 64; }
[ $# -eq 3 ] || usage "expected 3 arguments, got $#"
svc=$1 from=$2 to=$3
[[ $svc =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage "bad service name '$svc'"
for t in "$from" "$to"; do [[ $t =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || usage "bad tag '$t'"; done

TYPES=(application/vnd.oci.image.index.v1+json application/vnd.docker.distribution.manifest.list.v2+json
       application/vnd.oci.image.manifest.v1+json application/vnd.docker.distribution.manifest.v2+json)
err=$(mktemp); trap 'rm -f "$err"' EXIT

json=$(aws ecr batch-get-image --repository-name "$svc" --image-ids "imageTag=$from" \
  --accepted-media-types "${TYPES[@]}" --output json 2>"$err") \
  || { echo "ecr-retag: cannot read $svc:$from: $(head -n 1 "$err")" >&2; exit 1; }
manifest=$(jq -r '.images[0].imageManifest // empty' <<<"$json" 2>/dev/null)
mtype=$(jq -r '.images[0].imageManifestMediaType // empty' <<<"$json" 2>/dev/null)
digest=$(jq -r '.images[0].imageId.imageDigest // empty' <<<"$json" 2>/dev/null)
if [ -z "$manifest" ]; then
  reason=$(jq -r '.failures[0] | "\(.failureCode // "?"): \(.failureReason // "?")"' <<<"$json" 2>/dev/null)
  echo "ecr-retag: $svc:$from not found in ECR (${reason:-no image returned}); refusing to retag, and nothing is rebuilt" >&2
  exit 2
fi
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "ecr-retag: $svc:$from has no valid digest (got '$digest')" >&2; exit 1; }
[ -n "$mtype" ] || { echo "ecr-retag: $svc:$from has no manifest media type" >&2; exit 1; }

if ! put=$(aws ecr put-image --repository-name "$svc" --image-tag "$to" --image-manifest "$manifest" \
     --image-manifest-media-type "$mtype" --image-digest "$digest" --output json 2>"$err"); then
  # ImageAlreadyExistsException: <to-tag> already names this exact manifest (a re-run).
  if grep -q 'ImageAlreadyExistsException' "$err"; then
    echo "ecr-retag: $svc:$to already points at $digest" >&2
    echo "$digest"; exit 0
  fi
  echo "ecr-retag: cannot tag $svc@$digest as $to: $(head -n 1 "$err")" >&2
  exit 1
fi
got=$(jq -r '.image.imageId.imageDigest // empty' <<<"$put" 2>/dev/null)
[ "$got" = "$digest" ] || { echo "ecr-retag: put-image answered digest '$got', expected $digest" >&2; exit 1; }
echo "ecr-retag: $svc:$from ($digest) is now also $svc:$to" >&2
echo "$digest"
