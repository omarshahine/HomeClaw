#!/usr/bin/env bash
# Capture raw App Store screenshots with the Catalyst XCUITests, no fastlane.
#
# Replaces the old `screenshots` lane. HomeClaw is a Mac Catalyst app, so this
# is not `fastlane snapshot`/SnapshotHelper on a simulator: the UI tests run the
# real app on this Mac in demo mode and attach one XCTAttachment per shot
# (Sources/HomeClawUITests/ScreenshotTests.swift). This script:
#
#   1. regenerates the Xcode project (xcodegen)
#   2. runs the HomeClawUITests scheme against "platform=macOS,variant=Mac
#      Catalyst" into a result bundle
#   3. extracts the attachments with xcparse and strips xcparse's
#      `_<index>_<UUID>` suffix, so "01_Onboarding" lands as 01_Onboarding.png
#   4. copies them into appstore/screenshots/<language>/, next to the
#      hand-captured terminal shots (see appstore/MANUAL_SCREENSHOTS.md)
#
#   scripts/screenshots.sh
#
# Demo mode (`--ui-test-demo`, set by the tests) makes HomeKitManager serve
# DemoFixtures instead of HMHomeManager, so no real home data is ever shown.
# The tests drive windows on this Mac's screen; leave it alone while they run.
set -euo pipefail

# ─── CONFIG ──────────────────────────────────────────────────────────────
PROJECT="HomeClaw.xcodeproj"
SCHEME="HomeClawUITests"
UI_TEST_TARGET="HomeClawUITests"
DESTINATION="platform=macOS,variant=Mac Catalyst"
LANGUAGES=("en-US")
# The old lane deleted every PNG in the output folder first. That folder also
# holds the hand-captured terminal shots (03_TUI, 04_CLI_List, 05_CLI_Toggle),
# which the tests can't produce, so captures now overwrite by name instead.
CLEAR_PREVIOUS=false
TEAM_ID_VARS="HOMEKIT_TEAM_ID APPLE_TEAM_ID"
# ─────────────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/appstore/screenshots"
RESULT_DIR="$REPO_ROOT/.asc/screenshots"
LOG_DIR="$REPO_ROOT/.asc/logs"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

case "${1:-}" in
  "") ;;
  -h|--help) awk 'NR > 1 { if (!/^#/) exit; print }' "$0"; exit 0 ;;
  *) die "unknown option: $1" ;;
esac

move_to_trash() {
  if command -v trash >/dev/null; then trash "$@"; else mv -f "$@" "$HOME/.Trash/"; fi
}

command -v xcodegen >/dev/null || die "xcodegen not installed. brew install xcodegen"
command -v xcparse >/dev/null || die "xcparse not installed. brew install chargepoint/xcparse/xcparse"

# The UI tests sign the app for this Mac; the team comes from .env.local.
team=""
for var in $TEAM_ID_VARS; do
  value="${!var:-}"
  if [[ -z "$value" && -f "$REPO_ROOT/.env.local" ]]; then
    # shellcheck source=/dev/null
    value=$(source "$REPO_ROOT/.env.local" >/dev/null 2>&1; printf '%s' "${!var:-}")
  fi
  [[ "$value" == "YOUR_TEAM_ID" ]] && value=""
  if [[ -n "$value" ]]; then team="$value"; break; fi
done
[[ -n "$team" ]] || die "no team id (set one of: $TEAM_ID_VARS in .env.local)."

mkdir -p "$LOG_DIR" "$RESULT_DIR"
step "Generate Xcode project"
xcodegen generate --use-cache --spec "$REPO_ROOT/project.yml" --project "$REPO_ROOT" >"$LOG_DIR/screenshots-xcodegen.log" 2>&1 \
  || die "xcodegen failed. Log: $LOG_DIR/screenshots-xcodegen.log"
# The app's post-build script compiles the OpenClaw plugin with the hoisted tsc.
[[ -d "$REPO_ROOT/node_modules" ]] || (cd "$REPO_ROOT" && npm ci --no-audit --no-fund >"$LOG_DIR/screenshots-npm.log" 2>&1) \
  || die "npm ci failed. Log: $LOG_DIR/screenshots-npm.log"

for language in "${LANGUAGES[@]}"; do
  out="$OUTPUT_DIR/$language"
  mkdir -p "$out"
  if $CLEAR_PREVIOUS; then
    old=()
    while IFS= read -r -d '' f; do old+=("$f"); done < <(find "$out" -maxdepth 1 -name '*.png' -print0)
    [[ ${#old[@]} -eq 0 ]] || move_to_trash "${old[@]}"
  fi

  # A fresh result bundle and extraction folder per run (xcodebuild refuses
  # to overwrite a result bundle).
  run=$(mktemp -d "$RESULT_DIR/run.XXXXXX")
  result="$run/screenshots.xcresult"
  log="$LOG_DIR/screenshots-$language.log"
  step "$SCHEME on $DESTINATION — $language"
  status=0
  xcodebuild test \
    -project "$REPO_ROOT/$PROJECT" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -only-testing:"$UI_TEST_TARGET" \
    -resultBundlePath "$result" \
    -enableCodeCoverage NO \
    DEVELOPMENT_TEAM="$team" -allowProvisioningUpdates \
    >"$log" 2>&1 || status=$?
  if [[ $status -ne 0 ]]; then
    grep -E "error:|failed|Failing tests|XCTAssert" "$log" | tail -n 20 >&2 || true
    die "UI tests failed (exit $status). Full log: $log"
  fi

  shots="$run/attachments"
  mkdir -p "$shots"
  xcparse screenshots "$result" "$shots" >>"$log" 2>&1 || die "xcparse failed. Log: $log"

  # xcparse emits `01_Onboarding_0_<UUID>.png`. App Store order follows the
  # filename, so strip the suffix back to the attachment name set in
  # ScreenshotTests.
  count=0
  while IFS= read -r -d '' f; do
    base=$(basename "$f" .png)
    clean=$(printf '%s' "$base" | sed -E 's/_[0-9]+_[A-Fa-f0-9-]+$//')
    if [[ -e "$shots/$clean.png.done" ]]; then
      die "two test attachments clean to the same filename: $clean.png. Rename one of the XCTAttachment names in ScreenshotTests."
    fi
    : >"$shots/$clean.png.done"
    cp "$f" "$out/$clean.png"
    printf '    %s\n' "$language/$clean.png"
    count=$((count + 1))
  done < <(find "$shots" -name '*.png' -print0 | sort -z)
  [[ $count -gt 0 ]] || die "tests passed but xcparse found no screenshot attachments in $result."
done

printf '\nRaw screenshots in %s. Next: scripts/release.sh frame\n' "$OUTPUT_DIR"
