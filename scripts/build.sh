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

# ─── Derive version from git ──────────────────────────────────────────

GIT_TAG=$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo "v0.0.1")
MARKETING_VERSION="${GIT_TAG#v}"
BUILD_NUMBER=$(git -C "$PROJECT_ROOT" rev-list --count HEAD)

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
echo ""

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

if xcodebuild "${XCODE_ARGS[@]}" 2>/dev/null; then
    step_done
else
    step_fail "xcodebuild failed"
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
