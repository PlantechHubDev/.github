import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "mutation-survivors.py")
FIX = os.path.join(HERE, "fixtures", "mutation")
MUTATIONS = os.path.join(FIX, "mutations.xml")
DIFF = os.path.join(FIX, "foo-line12.diff")


def run(*args):
    return subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True)


class TargetsTest(unittest.TestCase):
    # Production files that exist under the checkout root. A test file's target is
    # kept only when its production class exists (.github#31).
    EXISTING = ["src/main/java/a/b/C.java", "src/main/java/a/b/D.java", "src/main/java/a/E.java"]

    def targets(self, paths, existing=None):
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root)
        for rel in self.EXISTING if existing is None else existing:
            os.makedirs(os.path.join(root, os.path.dirname(rel)), exist_ok=True)
            open(os.path.join(root, rel), "w").close()
        changed = os.path.join(root, "changed.txt")
        with open(changed, "w") as f:
            f.write("\n".join(paths) + "\n")
        r = run("targets", "--changed", changed, "--root", root)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.last_probe = r.stdout.splitlines()[2]
        return r.stdout.splitlines()[:2]

    def probe(self, paths, existing=None):
        self.targets(paths, existing)
        return self.last_probe

    # probe: when no class maps but tests or build files changed, one production class for the
    # PR check to run PIT on, so PIT's green-suite check still runs (orchestration-service#596
    # changed only tests and build.gradle).
    def test_probe_same_package_class_for_unmapped_test(self):
        self.assertEqual(self.probe(["src/test/java/a/b/NoSuchThingTest.java"]), "probe=a.b.C")

    def test_probe_first_class_for_build_file_only(self):
        self.assertEqual(self.probe(["build.gradle"]), "probe=a.E")

    def test_probe_for_test_resources_and_gradle_dir(self):
        self.assertEqual(self.probe(["src/test/resources/pact/x.json"]), "probe=a.E")
        self.assertEqual(self.probe(["gradle/libs.versions.toml"]), "probe=a.E")

    def test_no_probe_for_docs_or_main_resources(self):
        self.assertEqual(self.probe(["README.md", "src/main/resources/app.yml", ".github/workflows/ci.yml"]), "probe=")

    def test_no_probe_when_targets_found(self):
        self.assertEqual(self.probe(["src/main/java/a/b/C.java", "build.gradle"]), "probe=")

    def test_no_probe_without_production_classes(self):
        self.assertEqual(self.probe(["build.gradle"], existing=[]), "probe=")

    def test_test_file_without_main_class_dropped(self):
        # 2026-11-18: OrchestrationDebtFieldsPassThroughTest mapped to a class that does not exist.
        out = self.targets(["src/test/java/a/b/NoSuchThingTest.java"])
        self.assertEqual(out, ["targets=", "whole="])

    def test_test_file_with_main_class_kept(self):
        out = self.targets(["src/test/java/a/b/CTest.java"])
        self.assertEqual(out, ["targets=a.b.C,a.b.C$*", "whole=a.b.C,a.b.C$*"])

    def test_existing_main_file_kept(self):
        # A renamed production class arrives under its new path, which exists.
        out = self.targets(["src/main/java/a/b/D.java"], existing=["src/main/java/a/b/D.java"])
        self.assertEqual(out, ["targets=a.b.D,a.b.D$*", "whole="])

    def test_unmapped_dropped_mapped_kept_in_one_change(self):
        out = self.targets(["src/test/java/a/b/NoSuchThingTest.java", "src/test/java/a/b/CTest.java"])
        self.assertEqual(out, ["targets=a.b.C,a.b.C$*", "whole=a.b.C,a.b.C$*"])

    def test_main_file_maps_to_class_glob(self):
        self.assertEqual(self.targets(["src/main/java/a/b/C.java"]), ["targets=a.b.C,a.b.C$*", "whole="])

    def test_test_files_map_to_whole_class(self):
        out = self.targets(["src/test/java/a/b/CTest.java", "src/test/java/a/b/DProperties.java"])
        self.assertEqual(out, ["targets=a.b.C,a.b.C$*,a.b.D,a.b.D$*", "whole=a.b.C,a.b.C$*,a.b.D,a.b.D$*"])

    def test_sibling_class_names_are_not_matched_by_prefix(self):
        out = self.targets(["src/test/java/a/b/CTest.java"])
        self.assertNotIn("a.b.C*", out[0])
        self.assertNotIn("a.b.CustomerService", out[0])

    def test_other_paths_ignored(self):
        out = self.targets(["src/main/resources/x.yml", "build.gradle", "src/test/java/a/b/Helper.java", "README.md"])
        self.assertEqual(out, ["targets=", "whole="])

    def test_mixed_and_deduplicated(self):
        out = self.targets(["src/main/java/a/b/C.java", "src/test/java/a/b/CTest.java", "src/main/java/a/E.java"])
        self.assertEqual(out, ["targets=a.b.C,a.b.C$*,a.E,a.E$*", "whole=a.b.C,a.b.C$*"])


class SurvivorsTest(unittest.TestCase):
    def survivors(self, *extra):
        r = run("survivors", "--mutations", MUTATIONS, "--repo", "example-service", "--sha", "abc1234", *extra)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def test_full_run_keeps_all_and_groups_nested_under_outer(self):
        items = self.survivors()
        self.assertEqual(sorted(i["class"] for i in items), ["a.b.Baz", "a.b.Foo"])
        foo = next(i for i in items if i["class"] == "a.b.Foo")
        self.assertIn("| Foo.java | 12 |", foo["body"])
        self.assertIn("| Foo.java | 30 |", foo["body"])
        self.assertNotIn("| Foo.java | 20 |", foo["body"])

    def test_title_format_is_exact(self):
        for i in self.survivors():
            self.assertEqual(i["title"], "Mutation survivors: " + i["class"])

    def test_diff_keeps_only_changed_lines(self):
        items = self.survivors("--diff", DIFF)
        self.assertEqual([i["class"] for i in items], ["a.b.Foo"])
        self.assertIn("| Foo.java | 12 |", items[0]["body"])
        self.assertNotIn("| Foo.java | 30 |", items[0]["body"])

    def test_whole_keeps_every_survivor_of_that_class(self):
        items = self.survivors("--diff", DIFF, "--whole", "a.b.Baz,a.b.Baz$*")
        self.assertEqual(sorted(i["class"] for i in items), ["a.b.Baz", "a.b.Foo"])
        baz = next(i for i in items if i["class"] == "a.b.Baz")
        self.assertIn("| Baz.java | 5 |", baz["body"])

    def test_whole_matches_exact_class_and_nested_not_siblings(self):
        # Foo$Bar (nested) matches "a.b.Foo,a.b.Foo$*"; a sibling "a.b.FooBar" must not match "a.b.Foo".
        items = self.survivors("--diff", os.path.join(FIX, "baz-line5.diff"), "--whole", "a.b.Foo,a.b.Foo$*")
        foo = next(i for i in items if i["class"] == "a.b.Foo")
        self.assertIn("| Foo.java | 30 |", foo["body"])
        self.assertIn("| Foo.java | 12 |", foo["body"])
        items = self.survivors("--diff", os.path.join(FIX, "baz-line5.diff"), "--whole", "a.b.Fo,a.b.Fo$*")
        self.assertEqual([i["class"] for i in items], ["a.b.Baz"])

    def test_body_has_ready_contract_headings(self):
        body = self.survivors()[0]["body"]
        for heading in ("**Repo:**", "## Problem and outcome", "## Acceptance criteria", "## Test strategy", "## Out of scope"):
            self.assertIn(heading, body)
        self.assertIn("example-service", body)
        self.assertIn("abc1234", body)
        self.assertIn("NO_COVERAGE", body)

    def test_no_survivors_prints_empty_array(self):
        with tempfile.TemporaryDirectory() as d:
            empty = os.path.join(d, "empty.diff")
            open(empty, "w").close()
            self.assertEqual(self.survivors("--diff", empty), [])

    def test_large_table_is_capped_below_issue_body_limit(self):
        rows = "".join(
            f"<mutation status='SURVIVED'><sourceFile>Big.java</sourceFile><mutatedClass>a.b.Big</mutatedClass>"
            f"<lineNumber>{n}</lineNumber><mutator>x.MathMutator</mutator><description>changed something here</description></mutation>"
            for n in range(1, 2001)
        )
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "m.xml")
            with open(path, "w") as f:
                f.write(f"<mutations>{rows}</mutations>")
            r = run("survivors", "--mutations", path, "--repo", "r", "--sha", "s")
        body = json.loads(r.stdout)[0]["body"]
        self.assertLess(len(body), 60000)
        self.assertIn("1800 more", body)
        self.assertIn("| Big.java | 1 |", body)

    def test_missing_mutations_file_exits_2(self):
        r = run("survivors", "--mutations", "/nonexistent.xml", "--repo", "r", "--sha", "s")
        self.assertEqual(r.returncode, 2)


class PitResultTest(unittest.TestCase):
    """pit-result tells "PIT could not run" from "PIT ran" (.github#31, #32)."""

    def pit_result(self, rc, log, report, *extra):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        mutations = os.path.join(d, "mutations.xml")
        if report:
            shutil.copy(MUTATIONS, mutations)
        r = run("pit-result", "--rc", str(rc), "--log", os.path.join(FIX, log), "--mutations", mutations, *extra)
        return r.returncode, r.stdout.splitlines()

    def test_whole_project_with_no_mutations_cannot_run(self):
        # A full run that finds nothing means the classpath or targetClasses glob is wrong.
        rc, out = self.pit_result(0, "pit-no-mutations.log", False, "--whole-project")
        self.assertEqual((rc, out), (1, ["result=cannot-run", "reason=PIT found no mutations in the whole project"]))

    def test_phrase_outside_pit_logger_does_not_count(self):
        # Test output that merely mentions the phrase must not turn a missing report into zero survivors.
        rc, out = self.pit_result(0, "pit-phrase-in-test-output.log", False)
        self.assertEqual((rc, out), (1, ["result=cannot-run", "reason=PIT wrote no report"]))

    def test_report_present_is_ok(self):
        rc, out = self.pit_result(0, "pit-ok.log", report=True)
        self.assertEqual((rc, out[0]), (0, "result=ok"))

    def test_no_report_with_no_mutations_found_is_zero_survivors(self):
        rc, out = self.pit_result(0, "pit-no-mutations.log", report=False)
        self.assertEqual((rc, out[0]), (0, "result=no-mutations"))

    def test_no_report_otherwise_cannot_run(self):
        rc, out = self.pit_result(0, "pit-ok.log", report=False)
        self.assertEqual((rc, out), (1, ["result=cannot-run", "reason=PIT wrote no report"]))

    def test_green_suite_failure_cannot_run(self):
        rc, out = self.pit_result(1, "pit-green-suite.log", report=False)
        self.assertEqual((rc, out), (1, ["result=cannot-run", "reason=tests fail under PIT without mutation"]))

    def test_other_gradle_failure_cannot_run(self):
        # A compile error or a dead minion JVM: Gradle fails before or during PIT.
        rc, out = self.pit_result(1, "pit-ok.log", report=True)
        self.assertEqual((rc, out), (1, ["result=cannot-run", "reason=PIT or Gradle error (exit 1)"]))

    def test_unreadable_log_exits_2(self):
        r = run("pit-result", "--rc", "0", "--log", "/nonexistent.log", "--mutations", "/nonexistent.xml")
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
