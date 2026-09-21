#!/usr/bin/env python3
"""CI harness regression tests using explicit fixtures, not Catalyst coverage."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("evidence", SCRIPTS / "verify-catalyst-results.py")
assert spec is not None and spec.loader is not None
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


def passing_fixture():
    return ({"result": "Passed", "totalTestCount": 1, "passedTests": 1,
             "failedTests": 0, "skippedTests": 0, "expectedFailures": 0},
            {"testNodes": [{"nodeType": "Unit test bundle", "name": "HomeClawTests",
                            "children": [{"nodeType": "Test Case", "name": "testFixture",
                                          "result": "Passed"}]}]})


class EvidenceTests(unittest.TestCase):
    def test_passed_fixture(self):
        self.assertIn("1 passed", evidence.verify(*passing_fixture()))

    def test_rejects_incomplete_or_skipped_summary(self):
        for key, value in (("totalTestCount", 0), ("passedTests", 0), ("failedTests", 1),
                           ("skippedTests", 1), ("expectedFailures", 1),
                           ("result", "Failed"), ("passedTests", True)):
            with self.subTest(key=key):
                summary, tests = passing_fixture()
                summary[key] = value
                with self.assertRaises(ValueError):
                    evidence.verify(summary, tests)

    def test_rejects_wrong_bundle_or_missing_cases(self):
        summary, tests = passing_fixture()
        tests["testNodes"][0]["name"] = "homeclaw-cliTests"
        with self.assertRaises(ValueError):
            evidence.verify(summary, tests)
        summary, tests = passing_fixture()
        tests["testNodes"][0]["children"] = []
        with self.assertRaises(ValueError):
            evidence.verify(summary, tests)

    def test_runner_status_propagation_with_stub_commands(self):
        # PATH points at fixtures; this never launches Xcode or compiles the app.
        for build_status, extract_status, expected in ((0, 0, 0), (65, 0, 65), (65, 9, 65), (0, 9, 9)):
            with self.subTest(build=build_status, extract=extract_status), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / "scripts").mkdir()
                (root / "bin").mkdir()
                for name in ("test-catalyst.sh", "verify-catalyst-results.py"):
                    shutil.copy(SCRIPTS / name, root / "scripts" / name)
                summary, tests = passing_fixture()
                (root / "summary.json").write_text(json.dumps(summary))
                (root / "tests.json").write_text(json.dumps(tests))
                build = root / "bin/xcodebuild"
                build.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > args.txt\nprintf "stub xcodebuild\\n"\nexit "$STUB_BUILD_STATUS"\n')
                extract = root / "bin/xcrun"
                extract.write_text('#!/bin/bash\nif [[ "$STUB_EXTRACT_STATUS" != 0 ]]; then exit "$STUB_EXTRACT_STATUS"; fi\n/bin/cat "$4.json"\n')
                build.chmod(0o755)
                extract.chmod(0o755)
                env = dict(os.environ, PATH=f'{root / "bin"}:{os.environ["PATH"]}',
                           STUB_BUILD_STATUS=str(build_status), STUB_EXTRACT_STATUS=str(extract_status),
                           CATALYST_EVIDENCE_DIR=str(root / "evidence"))
                env.pop("GITHUB_STEP_SUMMARY", None)
                result = subprocess.run(["bash", str(root / "scripts/test-catalyst.sh")],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                args = (root / "args.txt").read_text()
                self.assertTrue(args.startswith("test\n"))
                self.assertNotIn("-only-testing", args)
                self.assertNotIn("-skip-testing", args)
                self.assertEqual((root / "evidence/xcodebuild-exit-status.txt").read_text().strip(), str(build_status))


if __name__ == "__main__":
    unittest.main()
