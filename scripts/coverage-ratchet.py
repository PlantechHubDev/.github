#!/usr/bin/env python3
"""coverage-ratchet.py: fail when overall line coverage drops below the baseline.

Usage:
  coverage-ratchet.py --report <path> --format jacoco|lcov --baseline <file> [--write]

Prints "coverage <x.x>% (baseline <y.y>%)".
Exit 0: current >= baseline - 0.1 (or --write succeeded).
Exit 1: coverage dropped by more than 0.1 points.
Exit 2: report missing, empty or with no lines; or baseline file missing/invalid.
"""
import argparse
import os
import sys
import xml.etree.ElementTree as ET

TOLERANCE = 0.1
EPSILON = 1e-9
NO_BASELINE = "no coverage-baseline: add one with --write in this PR"


class UsageProblem(Exception):
    """A report or baseline problem that must exit 2 (never pass)."""


def jacoco_lines(path):
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as e:
        raise UsageProblem(f"cannot parse coverage report {path}: {e}")
    covered = missed = 0
    # Report-level counters are direct children of <report>.
    for counter in root.findall("counter"):
        if counter.get("type") == "LINE":
            covered += int(counter.get("covered", "0"))
            missed += int(counter.get("missed", "0"))
    return covered, covered + missed


def lcov_lines(path):
    lh = lf = 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("LH:"):
                lh += int(line[3:])
            elif line.startswith("LF:"):
                lf += int(line[3:])
    return lh, lf


def current_coverage(path, fmt):
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        raise UsageProblem(f"coverage report missing or empty: {path}")
    try:
        covered, total = (jacoco_lines if fmt == "jacoco" else lcov_lines)(path)
    except ValueError as e:
        raise UsageProblem(f"malformed coverage report {path}: {e}")
    if total <= 0:
        raise UsageProblem(f"coverage report has no lines: {path}")
    return 100.0 * covered / total


def read_baseline(path):
    if not os.path.isfile(path):
        raise UsageProblem(NO_BASELINE)
    with open(path, encoding="utf-8") as f:
        text = f.read().strip()
    try:
        return float(text)
    except ValueError:
        raise UsageProblem(f"coverage-baseline is not a number: {text!r}")


def main(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--report", required=True)
    p.add_argument("--format", required=True, choices=["jacoco", "lcov"])
    p.add_argument("--baseline", required=True)
    p.add_argument("--write", action="store_true")
    args = p.parse_args(argv)

    try:
        current = current_coverage(args.report, args.format)
        if args.write:
            with open(args.baseline, "w", encoding="utf-8") as f:
                f.write(f"{current:.1f}\n")
            print(f"wrote coverage-baseline {current:.1f}%")
            return 0
        baseline = read_baseline(args.baseline)
    except UsageProblem as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    print(f"coverage {current:.1f}% (baseline {baseline:.1f}%)")
    if current >= baseline - TOLERANCE - EPSILON:
        return 0
    print(f"error: line coverage dropped more than {TOLERANCE} points below the baseline", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
