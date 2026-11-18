#!/usr/bin/env bash
# Guards the name of the aggregate check. A workflow that runs on `push` and has a job (or a
# job `name:`) producing `ci-ok` must name it `ci-ok (push)` (or the conditional
# `${{ github.event_name == 'push' && 'ci-ok (push)' || 'ci-ok' }}`), never plain `ci-ok`:
# a push run's ci-ok could otherwise satisfy the PR's required `ci-ok` check.
# Also checks the README's trunk `ci.yml` example: it MUST NOT run on `push` and MUST have a
# job whose id is `ci-ok`.
# Python 3 stdlib only (PyYAML is not on the runners): the `on:` block and job headers are
# read by indentation, which is enough for the plain block style these workflows use.
# Usage: bash scripts/test-workflow-names.sh   (exit 0 when every case passes)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
FIX="$HERE/fixtures/workflow-names"
status=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; status=1; }

# check_names <workflow|readme> <file>: exit 0 clean, 1 with a message naming the file.
check_names() {
  python3 -I - "$1" "$2" <<'PY'
import re, sys

mode, path = sys.argv[1], sys.argv[2]
base = path.rsplit("/", 1)[-1]
COND = "${{ github.event_name == 'push' && 'ci-ok (push)' || 'ci-ok' }}"


def lines_of(text):
    out = []
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        out.append((len(raw) - len(raw.lstrip(" ")), raw.strip()))
    return out


def block(lines, key):
    """(inline value, child lines) of a top-level `key:`; None when absent."""
    for i, (ind, s) in enumerate(lines):
        m = re.match(r"""^["']?%s["']?\s*:\s*(.*)$""" % key, s)
        if ind == 0 and m:
            kids = []
            for j, s2 in lines[i + 1:]:
                if j == 0:
                    break
                kids.append((j, s2))
            return m.group(1), kids
    return None


def runs_on_push(lines):
    b = block(lines, "on")
    if b is None:
        return False
    inline, kids = b
    if inline:
        return "push" in re.split(r"[\s,\[\]{}]+", inline.split(" #")[0])
    if not kids:
        return False
    top = min(i for i, _ in kids)
    return any(re.match(r"^(-\s+)?push\s*(:|$)", s) for i, s in kids if i == top)


def jobs(lines):
    b = block(lines, "jobs")
    if b is None:
        return []
    _, kids = b
    if not kids:
        return []
    top = min(i for i, _ in kids)
    res = []
    for i, s in kids:
        m = re.match(r"^([A-Za-z0-9_-]+)\s*:\s*$", s)
        if i == top and m:
            res.append([m.group(1), None, top])
        elif res and i == res[-1][2] + (min(k for k, _ in kids if k > top) - top) and s.startswith("name:"):
            v = s[5:].strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            res[-1][1] = v
    return res


def push_problems(text):
    lines = lines_of(text)
    if not runs_on_push(lines):
        return []
    bad = []
    for jid, name, _ in jobs(lines):
        shown = name if name is not None else jid
        if name is None:
            producing = jid == "ci-ok"
        else:
            producing = "ci-ok" in name
        if producing and " ".join(shown.split()) not in ("ci-ok (push)", COND):
            bad.append(jid)
    return bad


def fail(msg):
    print("%s: %s" % (base, msg))
    raise SystemExit(1)


text = open(path, encoding="utf-8").read()
if mode == "workflow":
    bad = push_problems(text)
    if bad:
        fail("runs on push but job %s produces plain 'ci-ok'; name it %s or 'ci-ok (push)'" % (", ".join(bad), COND))
else:
    blocks = re.findall(r"^```ya?ml\n(.*?)^```", text, re.S | re.M)
    trunk = [b for b in blocks if "merge_group" in b and re.search(r"^jobs:", b, re.M)]
    if not trunk:
        fail("no trunk ci.yml example (a yaml block with merge_group and jobs) found")
    for b in trunk:
        lines = lines_of(b)
        if runs_on_push(lines):
            fail("the trunk ci.yml example must not run on push (a push run's ci-ok must not satisfy the PR check)")
        if not any(j[0] == "ci-ok" for j in jobs(lines)):
            fail("the trunk ci.yml example needs a job id ci-ok")
    for b in blocks:
        bad = push_problems(b)
        if bad:
            fail("a yaml example runs on push but job %s produces plain 'ci-ok'" % ", ".join(bad))
PY
}

# expect <name> <want-exit> <mode> <file> [text the message must contain]
expect() {
  local name=$1 want=$2 mode=$3 file=$4 text=${5:-} out code
  out=$(check_names "$mode" "$file" 2>&1); code=$?
  if [ "$code" != "$want" ]; then fail "$name" "exit $code want $want; output: $out"; return; fi
  if [ -n "$text" ] && [[ $out != *"$text"* ]]; then fail "$name" "output lacks '$text': $out"; return; fi
  pass "$name"
}

for f in "$FIX"/good-*.yml; do expect "fixture ok: $(basename "$f")" 0 workflow "$f"; done
for f in "$FIX"/bad-*.yml; do expect "fixture rejected: $(basename "$f")" 1 workflow "$f" "$(basename "$f")"; done
expect "readme fixture ok" 0 readme "$FIX/readme-good.md"
expect "readme fixture: push in on" 1 readme "$FIX/readme-bad-push.md" "must not run on push"
expect "readme fixture: no ci-ok job id" 1 readme "$FIX/readme-no-ciok-id.md" "job id ci-ok"
expect "readme fixture: no example" 1 readme "$FIX/readme-missing.md" "no trunk ci.yml example"

for f in "$ROOT"/.github/workflows/*.yml; do expect "repo workflow: $(basename "$f")" 0 workflow "$f"; done
expect "repo README trunk example" 0 readme "$ROOT/README.md"

# --- pth-sim.yml keeps the developer's Mac runner to merge-queue runs at a release tag.
# pthsim <file> <check|step>: "check" exits 0 when the pth-sim job has the job-level
# `if: github.event_name == 'merge_group'`, timeout-minutes 90, and a first step (before any
# checkout) that takes checks-ref through env CHECKS_REF; else 1 with a message. "step" prints
# that first step's run script, so the test can run it.
pthsim() {
  python3 -I - "$1" "$2" <<'PY'
import re, sys

path, mode = sys.argv[1], sys.argv[2]
raw = open(path, encoding="utf-8").read().splitlines()


def ind(l):
    return len(l) - len(l.lstrip(" "))


def fail(msg):
    print("%s: %s" % (path.rsplit("/", 1)[-1], msg))
    raise SystemExit(1)


# The pth-sim job's lines (under top-level jobs:).
start = next((i for i, l in enumerate(raw) if re.match(r"^  pth-sim:\s*$", l)), None)
if start is None:
    fail("no job pth-sim")
job = []
for l in raw[start + 1:]:
    if l.strip() and ind(l) <= 2:
        break
    job.append(l)
keys = {}
for l in job:
    m = re.match(r"^    ([a-z-]+):\s*(.*?)\s*$", l)
    if m:
        keys[m.group(1)] = m.group(2)
# Steps: the items at the first "- " indentation under steps:.
si = next((i for i, l in enumerate(job) if re.match(r"^    steps:\s*$", l)), None)
if si is None:
    fail("pth-sim has no steps")
steps, cur = [], None
for l in job[si + 1:]:
    if re.match(r"^      - ", l):
        cur = [l]
        steps.append(cur)
    elif cur is not None and (not l.strip() or ind(l) > 6):
        cur.append(l)
if not steps:
    fail("pth-sim has no steps")
first = steps[0]
text = "\n".join(first)
run, inrun = [], False
for l in first:
    if inrun:
        if l.strip() and ind(l) <= 8:
            inrun = False
        else:
            run.append(l[10:])
            continue
    if re.match(r"^        run:\s*\|\s*$", l):
        inrun = True

if mode == "step":
    print("\n".join(run))
    raise SystemExit(0)
cond = keys.get("if", "").strip()
m = re.match(r"^\$\{\{\s*(.*?)\s*\}\}$", cond)
if m:
    cond = m.group(1)
if cond != "github.event_name == 'merge_group'":
    fail("the pth-sim job needs the job-level if: github.event_name == 'merge_group' (got '%s')" % keys.get("if", ""))
if keys.get("timeout-minutes") != "90":
    fail("the pth-sim job needs timeout-minutes: 90 (got '%s')" % keys.get("timeout-minutes", ""))
if "actions/checkout" in text:
    fail("the first pth-sim step must check checks-ref before any checkout")
if not re.search(r"^\s+CHECKS_REF:\s*\$\{\{\s*inputs\.checks-ref\s*\}\}\s*$", text, re.M):
    fail("the first pth-sim step must take checks-ref through env CHECKS_REF")
if not run:
    fail("the first pth-sim step needs a run: | script")
PY
}
expect_pthsim() {
  local name=$1 want=$2 file=$3 text=${4:-} out code
  out=$(pthsim "$file" check 2>&1); code=$?
  if [ "$code" != "$want" ]; then fail "$name" "exit $code want $want; output: $out"; return; fi
  if [ -n "$text" ] && [[ $out != *"$text"* ]]; then fail "$name" "output lacks '$text': $out"; return; fi
  pass "$name"
}
# tagcheck <name> <want-exit> <checks-ref>: run pth-sim.yml's first step with CHECKS_REF set.
tagcheck() {
  local name=$1 want=$2 script out code
  script=$(pthsim "$ROOT/.github/workflows/pth-sim.yml" step) || { fail "$name" "cannot read the step: $script"; return; }
  out=$(CHECKS_REF=$3 bash -e -c "$script" 2>&1); code=$?
  if [ "$code" != "$want" ]; then fail "$name" "exit $code want $want; output: $out"; return; fi
  if [ "$want" != 0 ] && [[ $out != *"::error::"* ]]; then fail "$name" "no ::error:: in: $out"; return; fi
  pass "$name"
}
expect_pthsim "pth-sim fixture ok" 0 "$FIX/pthsim-good.yml"
expect_pthsim "pth-sim fixture: no job if" 1 "$FIX/pthsim-bad-no-if.yml" "github.event_name == 'merge_group'"
expect_pthsim "pth-sim fixture: checkout before the tag check" 1 "$FIX/pthsim-bad-checkout-first.yml" "before any checkout"
expect_pthsim "pth-sim fixture: timeout not 90" 1 "$FIX/pthsim-bad-timeout.yml" "timeout-minutes: 90"
expect_pthsim "repo pth-sim.yml: queue-only, tag-checked" 0 "$ROOT/.github/workflows/pth-sim.yml"
tagcheck "pth-sim tag check: v2.4.0 passes" 0 v2.4.0
tagcheck "pth-sim tag check: v10.0.12 passes" 0 v10.0.12
tagcheck "pth-sim tag check: a branch is rejected" 1 master
tagcheck "pth-sim tag check: a sha is rejected" 1 3d3c42e5aac5ba805825da76410c181273ba90b1
tagcheck "pth-sim tag check: a pre-release is rejected" 1 v2.4.0-rc.1
tagcheck "pth-sim tag check: empty is rejected" 1 ""
tagcheck "pth-sim tag check: a second line is rejected" 1 $'v2.4.0\nmaster'

exit $status
