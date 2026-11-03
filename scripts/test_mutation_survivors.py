import json
import os
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
    def targets(self, paths):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("\n".join(paths) + "\n")
        self.addCleanup(os.unlink, f.name)
        r = run("targets", "--changed", f.name)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.splitlines()

    def test_main_file_maps_to_class_glob(self):
        self.assertEqual(self.targets(["src/main/java/a/b/C.java"]), ["targets=a.b.C*", "whole="])

    def test_test_files_map_to_whole_class(self):
        out = self.targets(["src/test/java/a/b/CTest.java", "src/test/java/a/b/DProperties.java"])
        self.assertEqual(out, ["targets=a.b.C*,a.b.D*", "whole=a.b.C*,a.b.D*"])

    def test_other_paths_ignored(self):
        out = self.targets(["src/main/resources/x.yml", "build.gradle", "src/test/java/a/b/Helper.java", "README.md"])
        self.assertEqual(out, ["targets=", "whole="])

    def test_mixed_and_deduplicated(self):
        out = self.targets(["src/main/java/a/b/C.java", "src/test/java/a/b/CTest.java", "src/main/java/a/E.java"])
        self.assertEqual(out, ["targets=a.b.C*,a.E*", "whole=a.b.C*"])


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
        items = self.survivors("--diff", DIFF, "--whole", "a.b.Baz*")
        self.assertEqual(sorted(i["class"] for i in items), ["a.b.Baz", "a.b.Foo"])
        baz = next(i for i in items if i["class"] == "a.b.Baz")
        self.assertIn("| Baz.java | 5 |", baz["body"])

    def test_body_has_ready_contract_headings(self):
        body = self.survivors()[0]["body"]
        for heading in ("**Repo:**", "## Problem and outcome", "## Acceptance criteria", "## Test strategy", "## Out of scope"):
            self.assertIn(heading, body)
        self.assertIn("example-service", body)
        self.assertIn("abc1234", body)
        self.assertIn("NO_COVERAGE", body)

    def test_no_survivors_prints_empty_array(self):
        empty = os.path.join(FIX, "empty.diff")
        with open(empty, "w") as f:
            f.write("")
        self.addCleanup(os.unlink, empty)
        self.assertEqual(self.survivors("--diff", empty), [])

    def test_missing_mutations_file_exits_2(self):
        r = run("survivors", "--mutations", "/nonexistent.xml", "--repo", "r", "--sha", "s")
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
