#!/bin/bash
# Synthetic Catalyst UI flow. Requires a Mac on which normal Xcode UI testing works.
# Does not enable Automation Mode, grant permissions, or repair signing assets.
set -euo pipefail
cd "$(dirname "$0")/.."
evidence="${ONBOARDING_UI_EVIDENCE_DIR:-$PWD/.build/onboarding-ui}"
mkdir -p "$evidence"
evidence="$(cd "$evidence" && pwd)"
[[ ! -e "$evidence/Onboarding.xcresult" ]] || { echo 'Use a fresh evidence directory.' >&2; exit 2; }
xcodebuild test -project HomeClaw.xcodeproj -scheme HomeClawOnboardingTests \
  -configuration DebugUI -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$evidence/DerivedData" -resultBundlePath "$evidence/Onboarding.xcresult" \
  -only-testing:HomeClawUITests/OnboardingRegressionTests -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 180 \
  CODE_SIGNING_ALLOWED=YES "CODE_SIGN_IDENTITY=${HOMECLAW_UI_SIGNING_IDENTITY:-Apple Development}" \
  CODE_SIGN_ENTITLEMENTS= CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER= \
  2>&1 | tee "$evidence/xcodebuild.log"
