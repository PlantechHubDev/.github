#!/usr/bin/env bash
# image-digest.sh [--existing]: read JSON on stdin, print the image digest (sha256:<64 hex>).
# Default: docker/build-push-action metadata, key containerimage.digest.
# --existing: `aws ecr describe-images` output, imageDetails[0].imageDigest.
# Exit 1 when the digest is missing or malformed.
set -uo pipefail
case ${1-} in
  --existing) filter='.imageDetails[0].imageDigest // empty' ;;
  '')         filter='."containerimage.digest" // empty' ;;
  *) echo "usage: image-digest.sh [--existing] < json" >&2; exit 2 ;;
esac
digest=$(jq -r "$filter" 2>/dev/null) || { echo "input is not valid JSON" >&2; exit 1; }
if [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "$digest"
else
  echo "no valid sha256 digest in the input (got '$digest')" >&2
  exit 1
fi
