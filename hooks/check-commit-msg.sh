#!/bin/sh
# check-commit-msg.sh: check commit messages against the PlantechHub commit
# standard (Conventional Commits subject plus a Refs: trailer).
#
# Usage:
#   check-commit-msg.sh <msg-file>              commit-msg hook mode
#   check-commit-msg.sh --range <base>..<head>  CI mode: every non-merge
#                                               commit in the range
#
# Exit 0: every message passes (or is exempt).
# Exit 1: at least one failure; one "FAIL <sha|msg>: <reason>" line each.
# Exit 2: usage error, or git could not resolve the range.
#
# Format:
#   <type>(<scope>)!: <description>    type: feat fix docs test refactor
#                                      build ci chore perf revert; at most
#                                      72 characters; description starts
#                                      lower case, no trailing period;
#                                      "!" marks a breaking change
#   <blank line>
#   <body>                             optional
#   <blank line>
#   Refs: #123                         required; cross-repo form
#                                      PlantechHubDev/<repo>#123; several
#                                      allowed (more lines, or ", ")
#   BREAKING CHANGE: <what breaks>     required when "!" is used
#
# Exempt: merge commits; subjects starting 'Revert "', 'Merge pull request #'
# or "Merge branch '".
# fixup!/squash!/amend! subjects pass in hook mode and fail in CI mode,
# because they must be autosquashed (git rebase -i --autosquash) before merge.

set -u

# Byte-wise, locale-independent matching and lengths on every runner.
LC_ALL=C
export LC_ALL

TYPES='feat|fix|docs|test|refactor|build|ci|chore|perf|revert'
MAX_SUBJECT=72
REF='(#[0-9]+|PlantechHubDev/[A-Za-z0-9._-]+#[0-9]+)'
HEADER="^(${TYPES})(\\([a-z0-9][a-z0-9._/-]*\\))?!?: [^ ]"
SCISSORS='------------------------ >8 ------------------------'

failures=0

usage() {
  echo "usage: check-commit-msg.sh <msg-file> | --range <base>..<head>" >&2
  exit 2
}

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  failures=$((failures + 1))
}

# check_msg <label> <mode: hook|range> <message>
check_msg() {
  label=$1
  mode=$2
  msg=$3
  subject=$(printf '%s\n' "$msg" | sed -n '1p')

  case $subject in
    'Revert "'* | 'Merge pull request #'* | "Merge branch '"*)
      return 0 ;;
    'fixup!'* | 'squash!'* | 'amend!'*)
      if [ "$mode" = hook ]; then
        return 0
      fi
      fail "$label" "fixup!/squash!/amend! commit; autosquash it before merge (git rebase -i --autosquash)"
      return 0 ;;
    '')
      fail "$label" "empty commit message"
      return 0 ;;
  esac

  type=$(printf '%s\n' "$subject" | sed -n 's/^\([A-Za-z]*\).*/\1/p')
  if ! printf '%s\n' "$type" | grep -Eqx "$TYPES"; then
    fail "$label" "unknown type '$type' in subject '$subject' (allowed, lower case: $(echo "$TYPES" | tr '|' ' '))"
  elif ! printf '%s\n' "$subject" | grep -Eq "$HEADER"; then
    fail "$label" "subject '$subject' must be '<type>(<scope>)!: <description>' (scope lower case, optional; '!' optional)"
  else
    desc=${subject#*: }
    case $desc in
      [[:upper:]]*) fail "$label" "description must start lower case: '$subject'" ;;
    esac
    case $desc in
      *.) fail "$label" "subject must not end with a period: '$subject'" ;;
    esac
    if printf '%s\n' "$subject" | grep -Eq "^(${TYPES})(\\([^)]*\\))?!: "; then
      if ! printf '%s\n' "$msg" | sed '1d' | grep -Eq '^BREAKING[ -]CHANGE: [^ ]'; then
        fail "$label" "'!' marks a breaking change; add a 'BREAKING CHANGE: <what breaks>' footer"
      fi
    fi
  fi

  if [ "${#subject}" -gt "$MAX_SUBJECT" ]; then
    fail "$label" "subject is ${#subject} characters; the limit is $MAX_SUBJECT"
  fi

  line2=$(printf '%s\n' "$msg" | sed -n '2p')
  if [ -n "$line2" ]; then
    fail "$label" "line 2 must be blank (subject, blank line, body)"
  fi

  refs=$(printf '%s\n' "$msg" | sed '1d' | grep -E '^Refs:')
  if [ -z "$refs" ]; then
    fail "$label" "missing 'Refs: #<n>' trailer (cross-repo: 'Refs: PlantechHubDev/<repo>#<n>')"
  else
    bad=$(printf '%s\n' "$refs" | grep -Ev "^Refs: ${REF}(, *${REF})*\$")
    if [ -n "$bad" ]; then
      printf '%s\n' "$bad" | while IFS= read -r line; do
        printf 'FAIL %s: %s\n' "$label" "malformed '$line'; use 'Refs: #<n>' or 'Refs: PlantechHubDev/<repo>#<n>'"
      done
      failures=$((failures + 1))
    fi
  fi
}

# Hook mode: drop comment lines and everything from the scissors line down
# (git commit -v), trailing whitespace, and leading blank lines, as git's
# own cleanup does.
clean_hook_msg() {
  cc=$(git config --get core.commentChar 2>/dev/null || true)
  if [ "${#cc}" -ne 1 ]; then
    cc='#'
  fi
  awk -v cc="$cc" -v sc="$cc $SCISSORS" '
    $0 == sc { exit }
    substr($0, 1, 1) == cc { next }
    { print }
  ' "$1" | sed 's/[[:space:]]*$//' | awk 'NF { p = 1 } p'
}

[ $# -ge 1 ] || usage

if [ "$1" = --range ]; then
  [ $# -eq 2 ] || usage
  range=$2
  case $range in
    *...* | ..* | *..) usage ;;
    *..*) ;;
    *) usage ;;
  esac
  commits=$(git rev-list --reverse "$range") || {
    echo "check-commit-msg: git could not resolve range '$range'" >&2
    exit 2
  }
  for c in $commits; do
    words=$(git rev-list --parents -n 1 "$c" | wc -w)
    if [ "$words" -gt 2 ]; then
      continue # merge commit: exempt
    fi
    short=$(git rev-parse --short=12 "$c")
    check_msg "$short" range "$(git log -1 --format=%B "$c")"
  done
else
  [ $# -eq 1 ] || usage
  [ -r "$1" ] || {
    echo "check-commit-msg: cannot read '$1'" >&2
    exit 2
  }
  merge_head=$(git rev-parse --git-path MERGE_HEAD 2>/dev/null || true)
  if [ -n "$merge_head" ] && [ -f "$merge_head" ]; then
    exit 0 # merge commit in progress: exempt
  fi
  check_msg msg hook "$(clean_hook_msg "$1")"
fi

if [ "$failures" -gt 0 ]; then
  echo "check-commit-msg: $failures problem(s). Standard: engineering-handbook workflow.md, \"Commits\"." >&2
  exit 1
fi
exit 0
