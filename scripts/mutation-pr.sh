#!/usr/bin/env bash
# mutation-pr.sh <base-sha>
#
# The PR-time PIT check (.github#32; pth-context platform-ops decision 0132), run by
# mutation-pr.yml from the root of the caller's checkout, with this repo's scripts beside it
# (mutation-survivors.py in the same directory as this file).
#
# Runs PIT (`./gradlew pitest`) on the classes the PR changed since <base-sha>, using the
# nightly's target mapping (`mutation-survivors.py targets --root .`). It fails ONLY when PIT
# cannot run: tests fail under PIT without mutation, a PIT or Gradle error, or no report when
# mutations were found (`mutation-survivors.py pit-result`). Surviving mutants never fail it;
# they are counted in a notice and left to the nightly. When a test or build file changed,
# PIT's green-suite check must run: with no class mapped, PIT runs on one concrete probe
# class (`targets` prints it); when the targets had nothing to mutate (PIT then runs no
# tests), it re-runs on the probe, and fails if the suite still did not run. A PR with
# neither (docs, main resources, workflows, deletions) skips PIT and passes.
# Env: PACKAGES_USER, PACKAGES_TOKEN (GitHub Packages for the Gradle build). Exit 2: usage.
set -euo pipefail

if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "usage: mutation-pr.sh <base-sha>" >&2
  exit 2
fi
base=$1
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

git diff --name-only --diff-filter=d "$base...HEAD" > "$tmp/changed.txt"
python3 "$here/mutation-survivors.py" targets --changed "$tmp/changed.txt" --root . > "$tmp/targets.out"
targets=$(sed -n 's/^targets=//p' "$tmp/targets.out")
probe=$(sed -n 's/^probe=//p' "$tmp/targets.out")
if [ -z "$targets" ] && [ -n "$probe" ]; then
  # Tests or build files changed but no class maps (orchestration-service#596 changed only
  # tests and build.gradle). PIT's green-suite check runs the whole test suite whatever the
  # target, so one probe class is enough to catch a test that is red only under PIT.
  echo "No changed class to mutate, but tests or build files changed: running PIT on probe class $probe for its green-suite check."
  targets=$probe
elif [ -z "$targets" ]; then
  echo "No changed Java class to mutate and no test or build file changed: skipping PIT."
  exit 0
fi
echo "PIT targets: $targets"

report=build/reports/pitest/mutations.xml

# run_pit <targets>: runs PIT and classifies it; sets $result and $reason, returns pit-result's
# exit (0 ok or no-mutations, 1 cannot-run, 2 unreadable log).
run_pit() {
  local rc verdict=0
  rm -f "$report"
  set +e
  ./gradlew -PGITHUB_USER="${PACKAGES_USER:-}" -PGITHUB_TOKEN="${PACKAGES_TOKEN:-}" pitest "-PpitestTargetClasses=$1" 2>&1 | tee "$tmp/pit.log"
  rc=${PIPESTATUS[0]}
  set -e
  python3 "$here/mutation-survivors.py" pit-result --rc "$rc" --log "$tmp/pit.log" --mutations "$report" > "$tmp/result.out" || verdict=$?
  cat "$tmp/result.out"
  result=$(sed -n 's/^result=//p' "$tmp/result.out")
  reason=$(sed -n 's/^reason=//p' "$tmp/result.out")
  return "$verdict"
}

cannot_run() {
  echo "::error::PIT could not run on this PR's changed classes: $1. A test that passes under Gradle must also pass under PIT."
  exit 1
}

verdict=0
run_pit "$targets" || verdict=$?
[ "$verdict" -eq 0 ] || cannot_run "${reason:-pit-result exit $verdict}"

# PIT skips its tests when it finds nothing to mutate. When tests or build files changed, the
# green-suite check must still run, so re-run on the probe class (a concrete class).
if [ "$result" = no-mutations ] && [ -n "$probe" ]; then
  case ",$targets," in
    *",$probe,"*) cannot_run "PIT's green-suite check did not run: probe class $probe has nothing to mutate" ;;
  esac
  echo "The changed classes have nothing to mutate, so PIT ran no tests: re-running on probe class $probe for its green-suite check."
  verdict=0
  run_pit "$probe" || verdict=$?
  [ "$verdict" -eq 0 ] || cannot_run "${reason:-pit-result exit $verdict}"
  [ "$result" != no-mutations ] || cannot_run "PIT's green-suite check did not run: probe class $probe has nothing to mutate"
fi

if [ "$result" = ok ]; then
  survivors=$(grep -cE "status='(SURVIVED|NO_COVERAGE)'" "$report" || true)
  echo "::notice::PIT ran: $survivors surviving mutants. They never fail a PR; the nightly files them as mutation-survivor issues."
else
  echo "::notice::PIT found nothing to mutate in the changed classes, and no test or build file changed."
fi
