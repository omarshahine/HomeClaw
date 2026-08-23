#!/bin/bash
set -euo pipefail

# HomeClaw — Build & Install Script
# Builds the unified Mac Catalyst app via XcodeGen + xcodebuild.
# The app includes HomeKit access, socket server, macOSBridge menu bar,
# CLI tool, MCP server, and OpenClaw plugin.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HomeClaw"

# Load local configuration (Team ID, etc.)
if [[ -f "$PROJECT_ROOT/.env.local" ]]; then
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/.env.local"
fi
TEAM_ID="${HOMEKIT_TEAM_ID:-}"

# ─── Toolchain ──────────────────────────────────────────────────────
#
# The project pins its Xcode in .xcode-version. Machines with several Xcodes
# installed otherwise build against whatever `xcode-select` happens to point at,
# which is invisible in the output and can differ from what releases are built
# with. Resolution order: DEVELOPER_DIR, XCODE_APP, .xcode-version, xcode-select.
#
# Find the Xcode.app whose CFBundleShortVersionString matches $1. Betas and
# release builds live side by side, so match on the version, not the app name.
find_xcode_by_version() {
    local want="$1" app version
    for app in /Applications/Xcode*.app; do
        [[ -d "$app" ]] || continue
        version="$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"
        if [[ "$version" == "$want" ]]; then
            printf '%s' "$app"
            return 0
        fi
    done
    return 1
}

if [[ -n "${XCODE_APP:-}" && -z "${DEVELOPER_DIR:-}" ]]; then
    DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
fi

XCODE_PIN_FILE="$PROJECT_ROOT/.xcode-version"
XCODE_PIN=""
if [[ -f "$XCODE_PIN_FILE" ]]; then
    XCODE_PIN="$(tr -d '[:space:]' < "$XCODE_PIN_FILE")"
fi

if [[ -z "${DEVELOPER_DIR:-}" && -n "$XCODE_PIN" ]]; then
    if PINNED_APP="$(find_xcode_by_version "$XCODE_PIN")"; then
        DEVELOPER_DIR="$PINNED_APP/Contents/Developer"
    else
        echo "Error: .xcode-version pins Xcode $XCODE_PIN, but no /Applications/Xcode*.app reports that version." >&2
        echo "  Installed:" >&2
        for app in /Applications/Xcode*.app; do
            [[ -d "$app" ]] || continue
            echo "    $app ($(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?"))" >&2
        done
        echo "  Install it, or override for this build: XCODE_APP=/Applications/Xcode.app scripts/build.sh ..." >&2
        exit 1
    fi
fi

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    if [[ ! -d "$DEVELOPER_DIR" ]]; then
        echo "Error: DEVELOPER_DIR does not exist: $DEVELOPER_DIR" >&2
        exit 1
    fi
    export DEVELOPER_DIR
fi
# Take the first line with parameter expansion rather than `| head -1`: head
# exits after one line, xcodebuild takes SIGPIPE, and under `set -o pipefail`
# the resulting 141 makes the assignment fail — which `set -e` turns into a
# silent abort of the whole script before it builds anything.
# `|| true` keeps a missing or broken xcode-select from aborting it the same way.
XCODE_VERSION="$(xcodebuild -version 2>/dev/null || true)"
XCODE_VERSION="${XCODE_VERSION%%$'\n'*}"
XCODE_PATH="$(xcode-select -p 2>/dev/null || true)"
XCODE_VERSION="${XCODE_VERSION:-unknown}"
XCODE_PATH="${XCODE_PATH:-unknown}"

# Defaults
BUILD_CONFIG="release"
DO_INSTALL=false
DO_CLEAN=false

# ─── Helpers ────────────────────────────────────────────────────────

bold()  { printf "\033[1m%s\033[0m" "$1"; }
green() { printf "\033[32m✓\033[0m"; }
red()   { printf "\033[31m✗\033[0m"; }

step() {
    local num="$1" total="$2" label="$3"
    printf "  [%s/%s] %s..." "$num" "$total" "$label"
}

step_done() {
    printf "  %s\n" "$(green)"
}

step_fail() {
    printf "  %s\n" "$(red)"
    echo "Error: $1" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: scripts/build.sh [options]

Options:
  --release       Build in release mode (default)
  --debug         Build in debug mode
  --install       Install to /Applications and symlink CLI
  --clean         Clean build artifacts first
  --team-id ID    Apple Developer Team ID (required, or set HOMEKIT_TEAM_ID)
  --help          Show this help

Environment:
  HOMEKIT_TEAM_ID   Same as --team-id (flag takes precedence)
  DEVELOPER_DIR     Xcode toolchain to build with (overrides .xcode-version)
  XCODE_APP         Path to an Xcode.app; shorthand for DEVELOPER_DIR

The project pins its Xcode in .xcode-version; the build resolves that to an
installed Xcode.app by version. DEVELOPER_DIR / XCODE_APP override the pin and
may also be set in .env.local. The Xcode in use is printed on every build.
EOF
    exit 0
}

# ─── Parse arguments ────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)      BUILD_CONFIG="release"; shift ;;
        --debug)        BUILD_CONFIG="debug"; shift ;;
        --install)      DO_INSTALL=true; shift ;;
        --clean)        DO_CLEAN=true; shift ;;
        --team-id)      TEAM_ID="$2"; shift 2 ;;
        --help|-h)      usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

# ─── Resolve team ID ───────────────────────────────────────────────

if [[ -z "$TEAM_ID" || "$TEAM_ID" == "YOUR_TEAM_ID" ]]; then
    echo "Error: No Apple Developer Team ID specified." >&2
    echo "  Use --team-id YOUR_ID or set HOMEKIT_TEAM_ID in your environment." >&2
    echo "  Find your Team ID at https://developer.apple.com/account#MembershipDetailsCard" >&2
    exit 1
fi

# ─── Derive version ──────────────────────────────────────────────────

GIT_TAG=$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo "v0.0.1")
MARKETING_VERSION="${GIT_TAG#v}"

# Build number: read from .build-number (single source of truth).
# The Xcode pre-build script increments this file on Release builds.
BUILD_NUMBER_FILE="$PROJECT_ROOT/.build-number"
if [[ -f "$BUILD_NUMBER_FILE" ]]; then
    BUILD_NUMBER=$(cat "$BUILD_NUMBER_FILE")
else
    BUILD_NUMBER=$(git -C "$PROJECT_ROOT" rev-list --count HEAD)
fi

# ─── Derived paths ──────────────────────────────────────────────────

DERIVED_DATA="$PROJECT_ROOT/.build/DerivedData"

# Map xcodebuild configuration name
XCODE_CONFIG="Release"
if [[ "$BUILD_CONFIG" == "debug" ]]; then
    XCODE_CONFIG="Debug"
fi

TOTAL_STEPS=4
CURRENT_STEP=0
next_step() { CURRENT_STEP=$((CURRENT_STEP + 1)); }

# ─── Main ───────────────────────────────────────────────────────────

echo ""
echo "$(bold "Building $APP_NAME...") ($BUILD_CONFIG) v$MARKETING_VERSION build $BUILD_NUMBER"
echo "  Toolchain: $XCODE_VERSION ($XCODE_PATH)"
echo ""

# Concurrent xcodebuild runs against the same project can wedge the build
# service: a run sits at the toolchain probe indefinitely, producing no object
# files, while `xcodebuild -list` keeps answering — which reads as a broken
# toolchain rather than contention, and costs a long time to diagnose. Refuse up
# front instead of hanging. Scoped to this project deliberately; unrelated
# xcodebuild runs elsewhere on the machine are not blocked.
EXISTING_BUILD="$(pgrep -f "xcodebuild.*$APP_NAME.xcodeproj" 2>/dev/null | grep -v "^$$\$" | head -1 || true)"
if [[ -n "$EXISTING_BUILD" ]]; then
    echo "Error: another xcodebuild is already running against $APP_NAME.xcodeproj (pid $EXISTING_BUILD)." >&2
    echo "  Concurrent builds wedge the build service. Wait for it, or: kill $EXISTING_BUILD" >&2
    exit 1
fi

# Clean if requested
if $DO_CLEAN; then
    echo "  Cleaning build artifacts..."
    rm -rf "$PROJECT_ROOT/.build"
    echo ""
fi

# Phase 1: Generate Xcode project
next_step
step "$CURRENT_STEP" "$TOTAL_STEPS" "Generating Xcode project"
if ! command -v xcodegen &>/dev/null; then
    step_fail "xcodegen not installed. Install with: brew install xcodegen"
fi
if xcodegen generate --spec "$PROJECT_ROOT/project.yml" --project "$PROJECT_ROOT" --use-cache 2>/dev/null; then
    step_done
else
    step_fail "xcodegen failed"
fi

# Phase 2: Build MCP server
next_step
step "$CURRENT_STEP" "$TOTAL_STEPS" "Building MCP server"
MCP_SERVER_JS="$PROJECT_ROOT/mcp-server/dist/server.js"
if command -v node &>/dev/null && [[ -f "$PROJECT_ROOT/mcp-server/build.mjs" ]]; then
    npm run --prefix "$PROJECT_ROOT" build:mcp 2>/dev/null || true
fi
step_done

# Phase 3: Build Catalyst app
next_step
step "$CURRENT_STEP" "$TOTAL_STEPS" "Building HomeClaw (Catalyst)"

# Verify HomeKit entitlement exists
ENTITLEMENTS="$PROJECT_ROOT/Resources/HomeClaw.entitlements"
if ! grep -q 'com.apple.developer.homekit' "$ENTITLEMENTS" 2>/dev/null; then
    step_fail "HomeKit entitlement missing from $ENTITLEMENTS"
fi

XCODE_ARGS=(
    -project "$PROJECT_ROOT/$APP_NAME.xcodeproj"
    -scheme "$APP_NAME"
    -configuration "$XCODE_CONFIG"
    -destination 'platform=macOS,variant=Mac Catalyst'
    -derivedDataPath "$DERIVED_DATA"
    -allowProvisioningUpdates
    DEVELOPMENT_TEAM="$TEAM_ID"
    MARKETING_VERSION="$MARKETING_VERSION"
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    ONLY_ACTIVE_ARCH=NO
    -quiet
)

# Keep the full log: -quiet plus a discarded stderr used to reduce every failure
# to "xcodebuild failed" with no way to tell why.
BUILD_LOG="$PROJECT_ROOT/.build/xcodebuild.log"
mkdir -p "$(dirname "$BUILD_LOG")"
if xcodebuild "${XCODE_ARGS[@]}" >"$BUILD_LOG" 2>&1; then
    step_done
else
    printf "  %s\n" "$(red)"
    echo "" >&2
    echo "xcodebuild failed. Last 40 lines of $BUILD_LOG:" >&2
    echo "" >&2
    tail -40 "$BUILD_LOG" >&2
    exit 1
fi

# Phase 4: Locate built app
next_step
step "$CURRENT_STEP" "$TOTAL_STEPS" "Verifying build"

CATALYST_PRODUCTS="$DERIVED_DATA/Build/Products/${XCODE_CONFIG}-maccatalyst"
APP_BUNDLE="$CATALYST_PRODUCTS/$APP_NAME.app"

if [[ -d "$APP_BUNDLE" ]]; then
    step_done
else
    step_fail "App not found at $APP_BUNDLE"
fi

# ─── Summary ────────────────────────────────────────────────────────

echo ""
echo "$(bold "Output:") $APP_BUNDLE"
# Re-read build number — Xcode pre-build script may have incremented it
if [[ -f "$BUILD_NUMBER_FILE" ]]; then
    BUILD_NUMBER=$(cat "$BUILD_NUMBER_FILE")
fi
echo "$(bold "Version:") $MARKETING_VERSION ($BUILD_NUMBER)"
echo ""

# Verify code signature
if codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null; then
    echo "  Code signature: valid"
else
    echo "  Code signature: INVALID (run codesign --verify --deep --strict to diagnose)"
fi

# Verify HomeKit entitlement on the app
if codesign -d --entitlements :- "$APP_BUNDLE" 2>/dev/null | grep -q "com.apple.developer.homekit"; then
    echo "  HomeKit entitlement: present"
else
    echo "  HomeKit entitlement: MISSING"
fi
echo ""

# ─── Install ────────────────────────────────────────────────────────

if $DO_INSTALL; then
    echo "$(bold "Installing...")"

    if [[ -d "/Applications/$APP_NAME.app" ]]; then
        /usr/bin/trash "/Applications/$APP_NAME.app" 2>/dev/null || rm -rf "/Applications/$APP_NAME.app"
    fi
    cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    echo "  Installed: /Applications/$APP_NAME.app"

    BUNDLED_CLI="/Applications/$APP_NAME.app/Contents/MacOS/homeclaw-cli"
    if [[ "$(uname -m)" == "arm64" ]]; then
        CLI_BIN_DIR="/opt/homebrew/bin"
    else
        CLI_BIN_DIR="/usr/local/bin"
    fi
    if ln -sf "$BUNDLED_CLI" "$CLI_BIN_DIR/homeclaw-cli" 2>/dev/null; then
        echo "  CLI linked: $CLI_BIN_DIR/homeclaw-cli -> $BUNDLED_CLI"
    else
        echo "  CLI symlink needs elevated permissions. Run:"
        echo "    sudo ln -sf '$BUNDLED_CLI' '$CLI_BIN_DIR/homeclaw-cli'"
    fi

    echo ""
    echo "$(bold "Done!") Launch from /Applications or run: open '/Applications/$APP_NAME.app'"
else
    echo "To install:  scripts/build.sh --install"
    echo "To launch:   open '$APP_BUNDLE'"
fi
echo ""
