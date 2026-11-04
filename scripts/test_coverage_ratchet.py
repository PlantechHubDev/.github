import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "coverage-ratchet.py")
FIX = os.path.join(HERE, "fixtures", "coverage")
MESSAGE = "no coverage-baseline: add one with --write in this PR"


def run(report, fmt, baseline, write=False):
    cmd = [sys.executable, SCRIPT, "--report", report, "--format", fmt, "--baseline", baseline]
    if write:
        cmd.append("--write")
    return subprocess.run(cmd, capture_output=True, text=True)


class CoverageRatchetTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def baseline(self, text):
        path = os.path.join(self.tmp.name, "coverage-baseline")
        with open(path, "w") as f:
            f.write(text)
        return path

    def test_jacoco_report_level_line_counter_gives_71_3(self):
        r = run(os.path.join(FIX, "jacoco-713.xml"), "jacoco", self.baseline("71.3\n"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "coverage 71.3% (baseline 71.3%)")

    def test_lcov_sums_lh_over_lf(self):
        r = run(os.path.join(FIX, "lcov-sample.info"), "lcov", self.baseline("71.0\n"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "coverage 71.0% (baseline 71.0%)")

    def test_within_tolerance_passes(self):
        # 71.3 current vs baseline 71.4: drop of 0.1 is tolerated.
        r = run(os.path.join(FIX, "jacoco-713.xml"), "jacoco", self.baseline("71.4\n"))
        self.assertEqual(r.returncode, 0)

    def test_drop_beyond_tolerance_fails(self):
        r = run(os.path.join(FIX, "jacoco-713.xml"), "jacoco", self.baseline("71.5\n"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("coverage 71.3% (baseline 71.5%)", r.stdout)

    def test_increase_passes(self):
        r = run(os.path.join(FIX, "jacoco-713.xml"), "jacoco", self.baseline("60.0\n"))
        self.assertEqual(r.returncode, 0)

    def test_current_71_25_vs_baseline_71_3_passes(self):
        report = os.path.join(self.tmp.name, "r.info")
        with open(report, "w") as f:
            f.write("SF:a\nLF:400\nLH:285\nend_of_record\n")  # 71.25
        self.assertEqual(run(report, "lcov", self.baseline("71.3\n")).returncode, 0)

    def test_current_71_1_vs_baseline_71_3_fails(self):
        report = os.path.join(self.tmp.name, "r.info")
        with open(report, "w") as f:
            f.write("SF:a\nLF:1000\nLH:711\nend_of_record\n")  # 71.1
        self.assertEqual(run(report, "lcov", self.baseline("71.3\n")).returncode, 1)

    def test_missing_report_exits_2(self):
        r = run(os.path.join(self.tmp.name, "nope.xml"), "jacoco", self.baseline("71.3\n"))
        self.assertEqual(r.returncode, 2)
        self.assertIn("report", r.stderr.lower())

    def test_report_with_zero_lines_exits_2(self):
        r = run(os.path.join(FIX, "jacoco-empty.xml"), "jacoco", self.baseline("71.3\n"))
        self.assertEqual(r.returncode, 2)

    def test_empty_report_file_exits_2(self):
        report = os.path.join(self.tmp.name, "empty.xml")
        open(report, "w").close()
        self.assertEqual(run(report, "jacoco", self.baseline("71.3\n")).returncode, 2)

    def test_lcov_with_zero_lines_exits_2(self):
        report = os.path.join(self.tmp.name, "z.info")
        with open(report, "w") as f:
            f.write("SF:a\nLF:0\nLH:0\nend_of_record\n")
        self.assertEqual(run(report, "lcov", self.baseline("71.3\n")).returncode, 2)

    def test_missing_baseline_exits_2_with_message(self):
        r = run(os.path.join(FIX, "jacoco-713.xml"), "jacoco", os.path.join(self.tmp.name, "absent"))
        self.assertEqual(r.returncode, 2)
        self.assertIn(MESSAGE, r.stderr + r.stdout)

    def test_write_creates_baseline(self):
        path = os.path.join(self.tmp.name, "coverage-baseline")
        r = run(os.path.join(FIX, "jacoco-713.xml"), "jacoco", path, write=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(path) as f:
            self.assertEqual(f.read(), "71.3\n")

    def test_write_with_missing_report_exits_2_and_writes_nothing(self):
        path = os.path.join(self.tmp.name, "coverage-baseline")
        r = run(os.path.join(self.tmp.name, "nope.xml"), "jacoco", path, write=True)
        self.assertEqual(r.returncode, 2)
        self.assertFalse(os.path.exists(path))


if __name__ == "__main__":
    unittest.main()
