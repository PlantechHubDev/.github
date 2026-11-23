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
        files = self.EXISTING if existing is None else existing
        if not isinstance(files, dict):
            files = {rel: None for rel in files}
        for rel, body in files.items():
            os.makedirs(os.path.join(root, os.path.dirname(rel)), exist_ok=True)
            name = os.path.basename(rel)[: -len(".java")]
            with open(os.path.join(root, rel), "w") as f:
                f.write(body if body is not None else f"public class {name} {{ int f() {{ return 1; }} }}\n")
        changed = os.path.join(root, "changed.txt")
        with open(changed, "w") as f:
            f.write("\n".join(paths) + "\n")
        r = run("targets", "--changed", changed, "--root", root)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.last_lines = r.stdout.splitlines()
        self.last_probe = self.last_lines[2]
        return self.last_lines[:2]

    def probe(self, paths, existing=None):
        self.targets(paths, existing)
        return self.last_probe

    # probe: when tests or build files changed, up to 5 concrete production classes (the changed
    # test's package first, then the project) for the PR check to run PIT on, so PIT's
    # green-suite check runs even when no class maps or the targets have nothing to mutate.
    # orchestration-service#596 changed only tests and build.gradle.
    def changed_flag(self, paths, existing=None):
        self.targets(paths, existing)
        return self.last_lines[3]

    def test_probe_package_first_then_project(self):
        self.assertEqual(self.probe(["src/test/java/a/b/NoSuchThingTest.java"]), "probe=a.b.C,a.b.D,a.E")

    def test_probe_project_classes_for_build_file_only(self):
        self.assertEqual(self.probe(["build.gradle"]), "probe=a.E,a.b.C,a.b.D")

    def test_probe_capped_at_five(self):
        existing = [f"src/main/java/p/K{n}.java" for n in range(8)]
        self.assertEqual(self.probe(["build.gradle"], existing), "probe=p.K0,p.K1,p.K2,p.K3,p.K4")

    def test_probe_for_test_resources_and_gradle_dir(self):
        self.assertEqual(self.probe(["src/test/resources/pact/x.json"]), "probe=a.E,a.b.C,a.b.D")
        self.assertEqual(self.probe(["gradle/libs.versions.toml"]), "probe=a.E,a.b.C,a.b.D")

    def test_probe_for_buildsrc_lombok_and_kts(self):
        for p in ("buildSrc/src/main/groovy/x.gradle", "lombok.config", "build.gradle.kts", "settings.gradle.kts"):
            self.assertEqual(self.probe([p]), "probe=a.E,a.b.C,a.b.D", p)

    def test_no_probe_for_docs_or_main_resources(self):
        paths = ["README.md", "src/main/resources/app.yml", ".github/workflows/ci.yml"]
        self.assertEqual(self.probe(paths), "probe=")
        self.assertEqual(self.changed_flag(paths), "tests_changed=0")

    def test_probe_also_when_targets_found_and_tests_changed(self):
        self.assertEqual(self.probe(["src/main/java/a/b/D.java", "src/test/java/a/b/CTest.java"]), "probe=a.b.C,a.b.D,a.E")

    def test_no_probe_when_only_production_code_changed(self):
        self.assertEqual(self.probe(["src/main/java/a/b/C.java"]), "probe=")
        self.assertEqual(self.changed_flag(["src/main/java/a/b/C.java"]), "tests_changed=0")

    def test_tests_changed_even_without_a_concrete_class(self):
        self.assertEqual(self.probe(["build.gradle"], existing=[]), "probe=")
        self.assertEqual(self.changed_flag(["build.gradle"], existing=[]), "tests_changed=1")

    def test_probe_skips_interfaces_enums_records_annotations(self):
        existing = {
            "src/main/java/a/b/A.java": "public interface A { void x(); }\n",
            "src/main/java/a/b/B.java": "/** class docs */\npublic enum B { X }\n",
            "src/main/java/a/b/C.java": "public record C(int x) {}\n",
            "src/main/java/a/b/D.java": "public @interface D {}\n",
            "src/main/java/a/b/E.java": "public final class E { int f() { return 1; } }\n",
            "src/main/java/a/b/F.java": "public sealed interface F permits G {}\n",
        }
        self.assertEqual(self.probe(["src/test/java/a/b/NoSuchThingTest.java"], existing), "probe=a.b.E")

    def test_type_detection_ignores_comments_strings_and_annotations(self):
        existing = {
            # License header with an unstarred line naming an interface: still a class.
            "src/main/java/a/b/A.java": "/*\n interface Xyz is licensed\n */\npublic class A { int f() { return 1; } }\n",
            # Header naming a class in front of an interface: still an interface.
            "src/main/java/a/b/B.java": "/*\n class Action\n */\npublic interface B {}\n",
            # A string in an annotation: still an interface.
            "src/main/java/a/b/C.java": '@Doc("a class Thing") public interface C {}\n',
            # A slash on the declaration line and a nested enum: still a class.
            "src/main/java/a/b/D.java": '@RequestMapping("/api") public class D { enum S { X } int f() { return 1; } }\n',
            # Foo.class literal before an interface declaration does not count.
            "src/main/java/a/b/E.java": "@RunWith(Foo.class)\npublic interface E {}\n",
            "src/main/java/a/b/F.java": "public abstract class F<T extends Comparable<T>> { int f() { return 1; } }\n",
        }
        self.assertEqual(self.probe(["src/test/java/a/b/NoSuchThingTest.java"], existing), "probe=a.b.A,a.b.D,a.b.F")

    def test_probe_not_taken_from_subpackage(self):
        # a.b has no class of its own (only a subpackage does): the project's classes follow.
        existing = ["src/main/java/a/b/c/Deep.java", "src/main/java/a/A0.java"]
        self.assertEqual(self.probe(["src/test/java/a/b/NoSuchThingTest.java"], existing), "probe=a.A0,a.b.c.Deep")

    def test_package_info_only_package_falls_back_to_project(self):
        existing = {"src/main/java/a/b/package-info.java": "package a.b;\n", "src/main/java/z/Top.java": None}
        self.assertEqual(self.probe(["src/test/java/a/b/NoSuchThingTest.java"], existing), "probe=z.Top")

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
