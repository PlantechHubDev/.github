#!/usr/bin/env bash
# Tests mutation-pr.sh (the PR-time PIT check, .github#32) in a throwaway git repo with a
# stub ./gradlew (scripts/fixtures/mutation-pr/bin/gradlew) that replays real PIT logs.
# The check must fail only when PIT cannot run; survivors never fail it.
# Usage: bash scripts/test-mutation-pr.sh   (exit 0 when every case passes)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
export MUTATION_FIX=$HERE/fixtures/mutation
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GRADLE_LOG=$T/gradle.log
unset GITHUB_ACTIONS GITHUB_STEP_SUMMARY
CHECK="$HERE/mutation-pr.sh"
status=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; status=1; }

# repo <changes...>: a repo with a base commit holding a.b.C and its test, then one commit
# that touches the given paths. Prints nothing; sets $REPO and $BASE.
repo() {
  REPO=$(mktemp -d "$T/repo.XXXX")
  git -C "$REPO" init -q -b develop
  git -C "$REPO" config user.email t@example.test; git -C "$REPO" config user.name t
  mkdir -p "$REPO/src/main/java/a/b" "$REPO/src/test/java/a/b"
  echo 'class C {}' > "$REPO/src/main/java/a/b/C.java"
  echo 'class CTest {}' > "$REPO/src/test/java/a/b/CTest.java"
  cp "$HERE/fixtures/mutation-pr/bin/gradlew" "$REPO/gradlew"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm base
  BASE=$(git -C "$REPO" rev-parse HEAD)
  for p in "$@"; do mkdir -p "$REPO/$(dirname "$p")"; echo "// $RANDOM" >> "$REPO/$p"; done
  git -C "$REPO" add -A; git -C "$REPO" commit -qm change
}
# run <name> <want-exit> <mode>: runs the check in $REPO; output in $out.
run() {
  local name=$1 want=$2 mode=$3
  : > "$GRADLE_LOG"
  out=$(cd "$REPO" && GRADLE_MODE=$mode PACKAGES_USER=u PACKAGES_TOKEN=x bash "$CHECK" "$BASE" 2>&1); code=$?
  if [ "$code" = "$want" ]; then pass "$name"; else fail "$name" "exit $code want $want; output: $out"; fi
}
has()     { if [[ $out == *"$2"* ]]; then pass "$1"; else fail "$1" "output lacks '$2': $out"; fi; }
called()  { if grep -qF -- "$2" "$GRADLE_LOG"; then pass "$1"; else fail "$1" "gradlew not called with '$2': $(cat "$GRADLE_LOG")"; fi; }
notcalled() { if [ -s "$GRADLE_LOG" ]; then fail "$1" "gradlew called: $(cat "$GRADLE_LOG")"; else pass "$1"; fi; }

# 1. Docs and resources only: no class to mutate, PIT skipped, pass.
repo README.md src/main/resources/app.yml
run "1 docs-only skips"                0 ok
notcalled "1 PIT not run"
has "1 says why"                       "No changed Java class to mutate"
# 2. Test-only change with no matching class, and the test is green under Gradle but red under
#    PIT (orchestration-service#596): PIT still runs, on a probe class, and the check fails.
repo src/test/java/a/b/HelperTest.java
run "2 test-only PIT failure fails"    1 green
called "2 probe class in test's package" '-PpitestTargetClasses=a.b.C'
has "2 says it is a probe"             "probe"
# 2b. build.gradle only (e.g. a new test-task system property): PIT runs on a probe class.
repo build.gradle
run "2b build-only passes when green"  0 ok
called "2b probe class"                '-PpitestTargetClasses=a.b.C'
# 3. Production change with surviving mutants: PIT runs on that class only, survivors pass.
repo src/main/java/a/b/C.java
run "3 survivors pass"                 0 ok
called "3 targets the changed class"   '-PpitestTargetClasses=a.b.C,a.b.C$*'
called "3 runs the pitest task"        "pitest"
has "3 reports survivors as notice"    "surviving mutants"
# 4. A test green under Gradle but red under PIT: fails, naming the cause.
repo src/test/java/a/b/CTest.java
run "4 green-suite failure fails"      1 green
has "4 names the cause"                "tests fail under PIT without mutation"
called "4 mapped test targets C"       '-PpitestTargetClasses=a.b.C,a.b.C$*'
# 5. Changed class with nothing to mutate (an interface): zero survivors, pass.
repo src/main/java/a/b/C.java
run "5 no mutations passes"            0 nomut
# 6. PIT exits 0 but writes no report and never said "No mutations found": fails.
repo src/main/java/a/b/C.java
run "6 missing report fails"           1 noreport
has "6 names the cause"                "PIT wrote no report"
# 7. A deleted class is not a target.
repo src/main/java/a/b/D.java
git -C "$REPO" rm -q src/main/java/a/b/C.java; git -C "$REPO" commit -qm delete
run "7 deleted class not targeted"     0 ok
called "7 only D targeted"             '-PpitestTargetClasses=a.b.D,a.b.D$*'
# 9. Gradle fails after PIT wrote its report: the exit code wins, the check fails.
repo src/main/java/a/b/C.java
run "9 report then failure fails"      1 okfail
has "9 names the cause"                "PIT or Gradle error (exit 1)"
# 8. No base: usage error, never a silent pass.
: > "$GRADLE_LOG"
out=$(cd "$REPO" && bash "$CHECK" 2>&1); code=$?
if [ "$code" = 2 ]; then pass "8 no base exits 2"; else fail "8 no base" "exit $code: $out"; fi
exit $status
