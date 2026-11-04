#!/usr/bin/env python3
"""mutation-survivors.py: pick PIT targets and turn surviving mutants into issues.

Usage:
  mutation-survivors.py targets --changed <file-with-paths>
  mutation-survivors.py survivors --mutations <mutations.xml> --repo <name> --sha <sha>
                                  [--diff <unified-diff> --whole <globs>]

targets prints two lines: "targets=<comma globs>" and "whole=<comma globs>".
  src/main/java/a/b/C.java            -> a.b.C,a.b.C$*  (not a.b.C*: that matches a.b.CustomerService)
  src/test/java/a/b/CTest.java        -> a.b.C,a.b.C$*  (also whole-class)
  src/test/java/a/b/CProperties.java  -> a.b.C,a.b.C$*  (also whole-class)
  anything else is ignored.

survivors prints a JSON array of {class, title, body}, one item per outer
production class. SURVIVED and NO_COVERAGE both count as survivors (no test
kills the mutant). With --diff only survivors on added or changed lines of the
diff are kept, plus every survivor of a class matching --whole.

Exit 2: unreadable input.
"""
import argparse
import fnmatch
import json
import re
import sys
import xml.etree.ElementTree as ET

SURVIVOR_STATUSES = ("SURVIVED", "NO_COVERAGE")
MAIN_RE = re.compile(r"^src/main/java/(.+)\.java$")
TEST_RE = re.compile(r"^src/test/java/(.+?)(?:Test|Properties)\.java$")
HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


class InputProblem(Exception):
    pass


def to_fqcn(path):
    return path.replace("/", ".")


def class_globs(fqcn):
    """Exact class plus its nested classes; never sibling names sharing a prefix."""
    return [fqcn, fqcn + "$*"]


def cmd_targets(args):
    try:
        with open(args.changed, encoding="utf-8") as f:
            paths = [line.strip() for line in f if line.strip()]
    except OSError as e:
        raise InputProblem(f"cannot read {args.changed}: {e}")
    targets, whole = [], []
    for p in paths:
        m = MAIN_RE.match(p)
        if m:
            for glob in class_globs(to_fqcn(m.group(1))):
                if glob not in targets:
                    targets.append(glob)
            continue
        m = TEST_RE.match(p)
        if m:
            for glob in class_globs(to_fqcn(m.group(1))):
                if glob not in targets:
                    targets.append(glob)
                if glob not in whole:
                    whole.append(glob)
    print("targets=" + ",".join(targets))
    print("whole=" + ",".join(whole))


def parse_diff(path):
    """Return {outer fqcn: set of new-side line numbers added or changed}."""
    changed = {}
    cls = None
    new_line = 0
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        raise InputProblem(f"cannot read {path}: {e}")
    for line in lines:
        if line.startswith("+++ "):
            name = line[4:].split("\t")[0]
            name = name[2:] if name.startswith("b/") else name
            m = MAIN_RE.match(name)
            cls = to_fqcn(m.group(1)) if m else None
            continue
        if line.startswith("--- ") or line.startswith("diff "):
            continue
        h = HUNK_RE.match(line)
        if h:
            new_line = int(h.group(1))
            continue
        if line.startswith("+"):
            if cls:
                changed.setdefault(cls, set()).add(new_line)
            new_line += 1
        elif line.startswith("-") or line.startswith("\\"):
            continue
        else:
            new_line += 1
    return changed


def read_mutations(path):
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as e:
        raise InputProblem(f"cannot read mutations report {path}: {e}")
    out = []
    for m in root.iter("mutation"):
        if m.get("status") not in SURVIVOR_STATUSES:
            continue
        mutated = (m.findtext("mutatedClass") or "").strip()
        out.append({
            "outer": mutated.split("$")[0],
            "mutated": mutated,
            "file": (m.findtext("sourceFile") or "").strip(),
            "line": int(m.findtext("lineNumber") or "0"),
            "mutator": (m.findtext("mutator") or "").strip().rsplit(".", 1)[-1],
            "description": (m.findtext("description") or "").strip(),
            "status": m.get("status"),
        })
    return out


def cell(text):
    return text.replace("|", "\\|").replace("\n", " ")


MAX_ROWS = 200  # keeps the body far below GitHub's 65,536-character issue limit


def body(repo, sha, fqcn, rows):
    rows = sorted(rows, key=lambda r: (r["file"], r["line"], r["mutator"]))
    omitted = max(0, len(rows) - MAX_ROWS)
    rows = rows[:MAX_ROWS]
    table = "\n".join(
        f"| {cell(r['file'])} | {r['line']} | {cell(r['mutator'])} | {cell(r['description'])} ({r['status']}) |"
        for r in rows
    )
    more = f"\n\n{omitted} more survivors in this class are not listed; the next nightly run lists them once these are killed." if omitted else ""
    return f"""**Repo:** {repo}

## Problem and outcome

Mutation testing (PIT, nightly run at `{sha}`) changed `{fqcn}` in the ways below and no test failed. Either the code is run without its result being checked, or no test runs it. Both `SURVIVED` and `NO_COVERAGE` mean no test kills the mutant. The outcome is a test suite that fails for each of these changes.

| File | Line | Mutator | Description |
| --- | --- | --- | --- |
{table}{more}

## Acceptance criteria

- [ ] Each mutant listed above is killed by a test, preferably a property test.
- [ ] No production code changes.
- [ ] The next nightly mutation run no longer lists these mutants.

## Test strategy

Unit tests only. platform-tests does not apply, because only tests change.

## Out of scope

- Production code changes.
- Mutants not listed above.
"""


def cmd_survivors(args):
    mutants = read_mutations(args.mutations)
    diff = parse_diff(args.diff) if args.diff else None
    whole = [g for g in (args.whole or "").split(",") if g]
    groups = {}
    for m in mutants:
        if diff is not None:
            in_whole = any(fnmatch.fnmatchcase(m["mutated"], g) for g in whole)
            if not in_whole and m["line"] not in diff.get(m["outer"], set()):
                continue
        groups.setdefault(m["outer"], []).append(m)
    items = [
        {"class": c, "title": f"Mutation survivors: {c}", "body": body(args.repo, args.sha, c, rows)}
        for c, rows in sorted(groups.items())
    ]
    print(json.dumps(items, indent=2))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("targets")
    t.add_argument("--changed", required=True)
    s = sub.add_parser("survivors")
    s.add_argument("--mutations", required=True)
    s.add_argument("--repo", required=True)
    s.add_argument("--sha", required=True)
    s.add_argument("--diff")
    s.add_argument("--whole")
    args = p.parse_args()
    try:
        (cmd_targets if args.cmd == "targets" else cmd_survivors)(args)
    except InputProblem as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
