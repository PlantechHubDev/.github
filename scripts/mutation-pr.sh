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
# they are counted in a notice and left to the nightly. A PR that changes no class to mutate
# (docs, resources, tests named after no class, deletions) skips PIT and passes.
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
if [ -z "$targets" ]; then
  echo "No changed Java class to mutate (docs, resources, tests named after no class, or deletions only): skipping PIT."
  exit 0
fi
echo "PIT targets: $targets"

set +e
./gradlew -PGITHUB_USER="${PACKAGES_USER:-}" -PGITHUB_TOKEN="${PACKAGES_TOKEN:-}" pitest "-PpitestTargetClasses=$targets" 2>&1 | tee "$tmp/pit.log"
rc=${PIPESTATUS[0]}
set -e

report=build/reports/pitest/mutations.xml
verdict=0
python3 "$here/mutation-survivors.py" pit-result --rc "$rc" --log "$tmp/pit.log" --mutations "$report" > "$tmp/result.out" || verdict=$?
cat "$tmp/result.out"
result=$(sed -n 's/^result=//p' "$tmp/result.out")
reason=$(sed -n 's/^reason=//p' "$tmp/result.out")
if [ "$verdict" -ne 0 ]; then
  echo "::error::PIT could not run on this PR's changed classes: ${reason:-pit-result exit $verdict}. A test that passes under Gradle must also pass under PIT."
  exit 1
fi
if [ "$result" = ok ]; then
  survivors=$(grep -cE "status='(SURVIVED|NO_COVERAGE)'" "$report" || true)
  echo "::notice::PIT ran: $survivors surviving mutants in the changed classes. They never fail a PR; the nightly files them as mutation-survivor issues."
else
  echo "::notice::PIT found nothing to mutate in the changed classes."
fi
