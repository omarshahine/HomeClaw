"""Mocked release-policy checks. No credentials, network, archives, or uploads."""
import subprocess
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "release.sh"
MOCKS = r'''
load_credentials() { :; }
marketing_version() { echo 1.0.5; }
version_id() { if [[ "${MOCK_EXISTS:-true}" == true ]]; then echo version-id; fi; }
version_state() { echo "${MOCK_STATE:-PREPARE_FOR_SUBMISSION}"; }
find_build() { echo "build-id 110 false"; }
push_metadata() { echo "METADATA" >&2; }
cmd_upload_screenshots() { echo "SCREENSHOTS" >&2; }
MOCK_RELEASE_TYPE=MANUAL
asc() {
  printf 'ASC' >&2; printf ' <%s>' "$@" >&2; printf '\n' >&2
  case "$1 $2" in
    'versions list')
      [[ "${MOCK_READ_FAIL:-false}" == false ]] || return 12
      printf '{"data":[{"id":"version-id","attributes":{"releaseType":"%s"}}]}\n' "$MOCK_RELEASE_TYPE" ;;
    'versions update')
      [[ "${ASC_READ_ONLY:-0}" != 1 ]] || return 13
      [[ "${MOCK_UPDATE_FAIL:-false}" == false ]] || return 14
      if [[ "${MOCK_UPDATE_STICKS:-true}" == true ]]; then MOCK_RELEASE_TYPE=AFTER_APPROVAL; fi
      echo '{}' ;;
    'versions create')
      [[ "${ASC_READ_ONLY:-0}" != 1 ]] || return 13
      MOCK_EXISTS=true; MOCK_RELEASE_TYPE=AFTER_APPROVAL
      echo '{}' ;;
    'review submit') echo '{}' ;;
    *) echo "Unexpected ASC call" >&2; return 15 ;;
  esac
}
'''


class AutoReleaseTests(unittest.TestCase):
    def shell(self, body):
        return subprocess.run(
            ["bash", "-c", 'source "$1" help >/dev/null\n' + MOCKS + body,
             "test", str(SCRIPT)], text=True, capture_output=True,
        )

    def test_release_and_submit_correct_manual_and_scheduled_versions(self):
        for command in ["release --skip-screenshots", "submit"]:
            for release_type in ["MANUAL", "SCHEDULED"]:
                with self.subTest(command=command, release_type=release_type):
                    result = self.shell(f"MOCK_RELEASE_TYPE={release_type}\nmain {command} --build 110\n")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("<--release-type> <AFTER_APPROVAL>", result.stderr)
                    self.assertEqual(result.stderr.count("ASC <versions> <list>"), 2)
                    self.assertIn("Release type verified: AFTER_APPROVAL", result.stdout)
                    self.assertIn("ASC <review> <submit>", result.stderr)

    def test_existing_automatic_policy_needs_no_update(self):
        result = self.shell("MOCK_RELEASE_TYPE=AFTER_APPROVAL\nmain submit --build 110\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("<update>", result.stderr)
        self.assertIn("ASC <review> <submit>", result.stderr)

    def test_new_release_is_created_with_automatic_policy_and_verified(self):
        result = self.shell("MOCK_EXISTS=false\nmain release --build 110 --skip-screenshots\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ASC <versions> <create>", result.stderr)
        self.assertIn("<--release-type> <AFTER_APPROVAL>", result.stderr)
        self.assertIn("Release type verified: AFTER_APPROVAL", result.stdout)

    def test_dry_run_describes_correction_without_writing(self):
        for command in ["release --skip-screenshots", "submit"]:
            with self.subTest(command=command):
                result = self.shell(f"main {command} --build 110 --dry-run\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Would set release type AFTER_APPROVAL", result.stdout)
                self.assertNotIn("<update>", result.stderr)
                self.assertNotIn("<create>", result.stderr)
                self.assertIn("<--dry-run>", result.stderr)
                self.assertNotIn("<--confirm>", result.stderr)

    def test_failed_or_unconfirmed_update_stops_before_review(self):
        for scenario in ["MOCK_UPDATE_FAIL=true", "MOCK_UPDATE_STICKS=false", "MOCK_READ_FAIL=true"]:
            with self.subTest(scenario=scenario):
                result = self.shell(scenario + "\nmain submit --build 110\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("ASC <review> <submit>", result.stderr)

    def test_existing_review_gate_still_refuses_submission(self):
        result = self.shell("MOCK_STATE=IN_REVIEW\nmain submit --build 110\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("<update>", result.stderr)
        self.assertNotIn("ASC <review> <submit>", result.stderr)


if __name__ == "__main__":
    unittest.main()
