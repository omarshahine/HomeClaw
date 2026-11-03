"""Compatibility checks for the two vendored project-analysis scripts.

Run with python3 -m unittest discover -s tooling-compat -v, or use the
vendored skills/tests directory after copying this module into a skill root.
No tests query package servers or modify a project worktree.
"""
import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def load(name):
    source = Path(__file__).with_name(name + ".py")
    if not source.is_file():
        skill = {
            "check_spm_pins": "spm-build-analysis",
            "generate_optimization_report": "xcode-build-orchestrator",
        }[name]
        source = Path(__file__).resolve().parent.parent / skill / "scripts" / (name + ".py")
    spec = importlib.util.spec_from_file_location(name, source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pins = load("check_spm_pins")
report = load("generate_optimization_report")

LEGACY = '''
ABCDEF123456789012345678 /* XCRemoteSwiftPackageReference "Library" */ = {
    isa = XCRemoteSwiftPackageReference;
    repositoryURL = "https://example.com/Library.git";
    requirement = {kind = branch; branch = main;};
};
'''

JSON_PROJECT = '''{
  "configurations": ["Debug", "Release",],
  "packages": [
    {"kind":"remote", "repository":"https://example.com/Library.git/", "version":{"branch":"feature/tools",},},
    {"kind":"remote", "repository":"git@example.com:vendor/Utilities.git", "version":{"branch":"main",},},
    {"kind":"remote", "repository":"https://example.com/Pinned.git", "version":{"revision":"abc123",},},
    {"kind":"remote", "repository":"https://example.com/Versioned.git", "version":{"up-to-next-major-version":"1.0.0",},},
    {"kind":"local", "path":"../Local", "version":{"branch":"main",},},
  ],
  "build-settings": {
    "SWIFT_OPTIMIZATION_LEVEL[config=Debug]":"-Onone",
    "SWIFT_OPTIMIZATION_LEVEL":"-O",
    "ONLY_ACTIVE_ARCH[config=Debug]":"YES",
    "ONLY_ACTIVE_ARCH":"NO",
    "HEADER_SEARCH_PATHS":["$(inherited)", "Libraries",],
    "SDKROOT":"iphoneos",
  },
  "targets": [{
    "name":"App",
    "build-settings": {
      "SWIFT_OPTIMIZATION_LEVEL[config=Debug]":"-Osize",
      "SWIFT_OPTIMIZATION_LEVEL[config=Release]":"-O",
      "SWIFT_OPTIMIZATION_LEVEL[config=Debug][sdk=iphoneos*]":"-O",
    },
  },],
}'''


class ProjectFormatTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name) / "App.xcodeproj"
        self.project.mkdir()

    def json_project(self, text=JSON_PROJECT):
        path = self.project / "project.xcproj"
        path.write_text(text)
        return path

    def test_legacy_spm_api_is_preserved(self):
        expected = [{"name":"Library", "url":"https://example.com/Library.git", "branch":"main"}]
        self.assertEqual(pins.find_branch_pins(LEGACY), expected)
        (self.project / "project.pbxproj").write_text(LEGACY)
        self.assertEqual(pins.read_branch_pins(self.project), expected)

    def test_extended_json_branch_pins_only(self):
        self.json_project()
        self.assertEqual(pins.read_branch_pins(self.project), [
            {"name":"Library", "url":"https://example.com/Library.git/", "branch":"feature/tools"},
            {"name":"Utilities", "url":"git@example.com:vendor/Utilities.git", "branch":"main"},
        ])

    def test_package_explicit_name_is_preserved(self):
        self.assertEqual(pins.find_json_branch_pins({"packages":[{
            "kind":"remote", "name":"Alias.git", "repository":"https://example.com/Repo.git",
            "version":{"branch":"main"},
        }]} )[0]["name"], "Alias.git")

    def test_spm_cli_output_and_network_boundary(self):
        self.json_project()
        args = argparse.Namespace(project=str(self.project), json=True)
        output = io.StringIO()
        with patch.object(pins, "parse_args", return_value=args), patch.object(pins, "check_tags", return_value=["1.0.0"]) as network, contextlib.redirect_stdout(output):
            self.assertEqual(pins.main(), 0)
        result = json.loads(output.getvalue())
        self.assertEqual([pin["name"] for pin in result], ["Library", "Utilities"])
        self.assertTrue(all(pin["tags_available"] for pin in result))
        self.assertEqual(network.call_count, 2)

    def test_dual_definitions_fail_before_network(self):
        self.json_project()
        (self.project / "project.pbxproj").write_text(LEGACY)
        args = argparse.Namespace(project=str(self.project), json=True)
        errors = io.StringIO()
        with patch.object(pins, "parse_args", return_value=args), patch.object(pins, "check_tags") as network, contextlib.redirect_stderr(errors):
            self.assertEqual(pins.main(), 1)
        self.assertIn("exactly one", errors.getvalue())
        network.assert_not_called()
        with self.assertRaisesRegex(ValueError, "exactly one"):
            report._read_project_configs(self.project)

    def test_missing_definitions_fail_explicitly(self):
        for reader in [pins.read_branch_pins, report._read_project_configs]:
            with self.assertRaisesRegex(ValueError, "exactly one"):
                reader(self.project)

    def test_malformed_json_spm_fails_before_network(self):
        self.json_project('{"packages": [broken}')
        args = argparse.Namespace(project=str(self.project), json=True)
        errors = io.StringIO()
        with patch.object(pins, "parse_args", return_value=args), patch.object(pins, "check_tags") as network, contextlib.redirect_stderr(errors):
            self.assertEqual(pins.main(), 1)
        self.assertIn("Unable to read", errors.getvalue())
        network.assert_not_called()

    def test_configuration_settings_and_target_overrides(self):
        self.json_project()
        project, targets = report._read_project_configs(self.project)
        self.assertEqual(project["Debug"]["SWIFT_OPTIMIZATION_LEVEL"], "-Onone")
        self.assertEqual(project["Release"]["SWIFT_OPTIMIZATION_LEVEL"], "-O")
        self.assertEqual(project["Debug"]["HEADER_SEARCH_PATHS"], "$(inherited) Libraries")
        self.assertEqual(targets["App"]["Debug"]["SWIFT_OPTIMIZATION_LEVEL"], "-Osize")
        self.assertEqual(targets["App"]["Debug"]["SWIFT_OPTIMIZATION_LEVEL[sdk=iphoneos*]"], "-O")
        self.assertEqual(report._effective_value(project["Debug"], targets["App"]["Debug"], "ONLY_ACTIVE_ARCH"), "YES")
        self.assertTrue(any("target-level overrides" in line for line in report._audit_consistency(project, targets)))

    def test_wildcard_configs_and_declaration_order(self):
        result = report._json_config_settings({
            "VALUE[config=Debug]":"exact", "VALUE[config=*]":"fallback", "VALUE":"base",
            "FLAG[config=Debug*]":"matching", "FLAG[config=Release]":"other",
        }, "Debug")
        self.assertEqual(result, {"VALUE":"exact", "FLAG":"matching"})

    def test_legacy_report_api_and_dispatch_are_preserved(self):
        pbx = '''ABCDEF123456789012345678 /* Debug */ = {
        isa = XCBuildConfiguration; buildSettings = {SWIFT_OPTIMIZATION_LEVEL = "-Onone";};
        };'''
        parsed = report._parse_all_build_configs(pbx)
        self.assertEqual(parsed["ABCDEF123456789012345678"], ("Debug", {"SWIFT_OPTIMIZATION_LEVEL":"-Onone"}))
        (self.project / "project.pbxproj").write_text(pbx)
        with patch.object(report, "_parse_project_level_configs", return_value={"Debug":{"SDKROOT":"macosx"}}) as project, patch.object(report, "_parse_target_configs", return_value={}) as target:
            self.assertEqual(report._read_project_configs(self.project), ({"Debug":{"SDKROOT":"macosx"}}, {}))
        project.assert_called_once_with(pbx)
        target.assert_called_once_with(pbx)

    def test_report_cli_includes_json_settings_audit(self):
        self.json_project()
        benchmark = Path(self.temporary.name) / "benchmark.json"
        benchmark.write_text('{}')
        args = argparse.Namespace(benchmark=str(benchmark), recommendations=None, diagnostics=None, project_path=str(self.project), output=None)
        output = io.StringIO()
        with patch.object(report, "parse_args", return_value=args), contextlib.redirect_stdout(output):
            self.assertEqual(report.main(), 0)
        self.assertIn("Build Settings", output.getvalue())
        self.assertIn("`SWIFT_OPTIMIZATION_LEVEL`: `-Onone`", output.getvalue())

    def test_report_cli_rejects_malformed_json(self):
        self.json_project('{"configurations": [broken}')
        benchmark = Path(self.temporary.name) / "benchmark.json"
        benchmark.write_text('{}')
        args = argparse.Namespace(benchmark=str(benchmark), recommendations=None, diagnostics=None, project_path=str(self.project), output=None)
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(report, "parse_args", return_value=args), contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertEqual(report.main(), 1)
        self.assertEqual(output.getvalue(), "")
        self.assertIn("Unable to audit", errors.getvalue())

    def test_json_structural_errors_are_explicit(self):
        for invalid in [{"configurations":[]}, {"configurations":["Debug"], "build-settings":[]}]:
            self.json_project(json.dumps(invalid))
            with self.assertRaises(ValueError):
                report._read_project_configs(self.project)


if __name__ == "__main__":
    unittest.main()
