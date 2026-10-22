#!/bin/sh
# add-issue-ref.sh: prepare-commit-msg hook. On a work branch named
# <type>/<issue>-<slug>, append "Refs: #<issue>" to the message when it has
# no Refs: line yet.
#
# Usage: add-issue-ref.sh <msg-file> [<source> [<sha>]]
#   The arguments git passes to prepare-commit-msg. The pre-commit framework
#   passes only <msg-file> and puts <source> in PRE_COMMIT_COMMIT_MSG_SOURCE.
#
# A no-op when <source> is "merge", when HEAD is detached (rebase, bisect),
# or when the branch is not a work branch.

set -u

LC_ALL=C
export LC_ALL

[ $# -ge 1 ] || {
  echo "usage: add-issue-ref.sh <msg-file> [<source> [<sha>]]" >&2
  exit 2
}
msgfile=$1
source=${2:-${PRE_COMMIT_COMMIT_MSG_SOURCE:-}}

[ "$source" = merge ] && exit 0

branch=$(git symbolic-ref --short -q HEAD) || exit 0
issue=$(printf '%s\n' "$branch" | sed -n -E 's#^(feat|fix|chore|docs|hotfix)/([0-9]+)-.*#\2#p')
[ -n "$issue" ] || exit 0

grep -Eq '^Refs:' "$msgfile" && exit 0

cc=$(git config --get core.commentChar 2>/dev/null || true)
if [ "${#cc}" -ne 1 ]; then
  cc='#'
fi

# Append a blank line and the trailer. With git commit -v, insert it above
# the scissors line instead, because git discards everything below it.
tmp="$msgfile.add-issue-ref.$$"
awk -v ref="Refs: #$issue" -v sc="$cc ------------------------ >8 ------------------------" '
  !done && $0 == sc { print ""; print ref; done = 1 }
  { print }
  END { if (!done) { print ""; print ref } }
' "$msgfile" >"$tmp" && cat "$tmp" >"$msgfile"
status=$?
rm -f "$tmp"
exit "$status"
