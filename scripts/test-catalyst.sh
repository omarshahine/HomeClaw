#!/bin/bash
# Run the entire app-hosted unit suite, never the SPM CLI suite or a test slice.
# Generate HomeClaw.xcodeproj and install npm dependencies before invoking this.
set -euo pipefail
cd "$(dirname "$0")/.."

EVIDENCE_DIR="${CATALYST_EVIDENCE_DIR:-$PWD/.build/catalyst-test-evidence}"
mkdir -p "$EVIDENCE_DIR"
EVIDENCE_DIR="$(cd "$EVIDENCE_DIR" && pwd)"
RESULT="$EVIDENCE_DIR/HomeClawTests.xcresult"
# Refuse stale evidence rather than accidentally reporting an earlier run.
if [[ -e "$RESULT" ]]; then
  printf 'Result bundle already exists: %s; use a fresh CATALYST_EVIDENCE_DIR\n' "$RESULT" >&2
  exit 2
fi

# Serial execution keeps process-global diagnostics and loopback ports isolated.
# XCTest's timeouts make a hung test fail rather than silently excluding it.
set +e
xcodebuild test \
  -project HomeClaw.xcodeproj \
  -scheme HomeClawTests \
  -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$EVIDENCE_DIR/DerivedData" \
  -resultBundlePath "$RESULT" \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 30 \
  -maximum-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$EVIDENCE_DIR/xcodebuild.log"
statuses=("${PIPESTATUS[@]}")
set -e
printf '%s\n' "${statuses[0]}" > "$EVIDENCE_DIR/xcodebuild-exit-status.txt"

# Try to extract evidence even after failed tests; never mask xcodebuild's exit.
set +e
xcrun xcresulttool get test-results summary --path "$RESULT" > "$EVIDENCE_DIR/summary.json"
summary_status=$?
xcrun xcresulttool get test-results tests --path "$RESULT" > "$EVIDENCE_DIR/tests.json"
tests_status=$?
set -e
if [[ "${statuses[0]}" -ne 0 ]]; then exit "${statuses[0]}"; fi
if [[ "${statuses[1]}" -ne 0 ]]; then exit "${statuses[1]}"; fi
if [[ "$summary_status" -ne 0 ]]; then exit "$summary_status"; fi
if [[ "$tests_status" -ne 0 ]]; then exit "$tests_status"; fi
python3 scripts/verify-catalyst-results.py "$EVIDENCE_DIR/summary.json" "$EVIDENCE_DIR/tests.json"
