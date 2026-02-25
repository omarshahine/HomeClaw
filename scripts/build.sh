#!/bin/bash
set -euo pipefail

# HomeClaw — Build & Install Script
# Assembles a proper .app bundle from SPM + Xcode Catalyst builds,
# code-signs everything, and optionally installs to /Applications.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HomeClaw"
BUNDLE_DIR="$PROJECT_ROOT/.build/app"
APP_BUNDLE="$BUNDLE_DIR/$APP_NAME.app"
HELPER_PROJECT="$PROJECT_ROOT/Sources/HomeClawHelper"

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
SKIP_HELPER=false
APP_STORE=false

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
  --skip-helper   Skip building HomeClawHelper (faster iteration)
  --app-store     Build for Mac App Store (Apple Distribution signing, APP_STORE flag)
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
        --skip-helper)  SKIP_HELPER=true; shift ;;
        --app-store)    APP_STORE=true; shift ;;
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

SPM_BUILD_DIR="$PROJECT_ROOT/.build/$BUILD_CONFIG"
DERIVED_DATA="$PROJECT_ROOT/.build/DerivedData"
CATALYST_PRODUCTS="$DERIVED_DATA/Build/Products/Release-maccatalyst"
if [[ "$BUILD_CONFIG" == "debug" ]]; then
    CATALYST_PRODUCTS="$DERIVED_DATA/Build/Products/Debug-maccatalyst"
fi

# Entitlements paths (used by both build validation and code signing)
MAIN_ENTITLEMENTS="$PROJECT_ROOT/Resources/HomeClaw.entitlements"
HELPER_ENTITLEMENTS="$HELPER_PROJECT/HomeClawHelper.entitlements"

# Map SPM config flag
SPM_CONFIG_FLAG="-c $BUILD_CONFIG"
if $APP_STORE; then
    SPM_CONFIG_FLAG="$SPM_CONFIG_FLAG -Xswiftc -DAPP_STORE"
fi

# Map xcodebuild configuration name
XCODE_CONFIG="Release"
if [[ "$BUILD_CONFIG" == "debug" ]]; then
    XCODE_CONFIG="Debug"
fi

# ─── Detect signing identity ───────────────────────────────────────

detect_signing_identity() {
    local identity
    local search_term
    if $APP_STORE; then
        search_term="Apple Distribution"
    else
        search_term="Apple Development"
    fi
    identity=$(security find-identity -v -p codesigning | grep "$search_term" | head -1 | sed 's/.*"\(.*\)".*/\1/')
    if [[ -z "$identity" ]]; then
        echo "Warning: No $search_term signing identity found. Skipping code signing." >&2
        echo ""
    else
        echo "$identity"
    fi
}

# ─── Total steps ────────────────────────────────────────────────────

TOTAL_STEPS=5
if $SKIP_HELPER; then
    TOTAL_STEPS=4
fi

CURRENT_STEP=0
next_step() { CURRENT_STEP=$((CURRENT_STEP + 1)); }

# ─── Main ───────────────────────────────────────────────────────────

echo ""
if $APP_STORE; then
    echo "$(bold "Building $APP_NAME...") ($BUILD_CONFIG, App Store) v$MARKETING_VERSION build $BUILD_NUMBER"
else
    echo "$(bold "Building $APP_NAME...") ($BUILD_CONFIG) v$MARKETING_VERSION build $BUILD_NUMBER"
fi
echo ""

# Clean if requested
if $DO_CLEAN; then
    echo "  Cleaning build artifacts..."
    rm -rf "$PROJECT_ROOT/.build"
    echo ""
fi

# Phase 1: Build SPM targets
next_step
step "$CURRENT_STEP" "$TOTAL_STEPS" "Building homeclaw ($BUILD_CONFIG)"
if swift build $SPM_CONFIG_FLAG --package-path "$PROJECT_ROOT" --product homeclaw 2>/dev/null; then
    step_done
else
    step_fail "swift build --product homeclaw failed"
fi

next_step
step "$CURRENT_STEP" "$TOTAL_STEPS" "Building homeclaw-cli ($BUILD_CONFIG)"
if swift build $SPM_CONFIG_FLAG --package-path "$PROJECT_ROOT" --product homeclaw-cli 2>/dev/null; then
    step_done
else
    step_fail "swift build --product homeclaw-cli failed"
fi

# Phase 2: Build HomeClawHelper (Mac Catalyst)
if ! $SKIP_HELPER; then
    next_step
    step "$CURRENT_STEP" "$TOTAL_STEPS" "Building HomeClawHelper (Catalyst)"

    # Ensure xcodeproj exists (regenerate from project.yml if missing)
    if [[ ! -d "$HELPER_PROJECT/HomeClawHelper.xcodeproj" ]]; then
        if command -v xcodegen &>/dev/null; then
            xcodegen generate --spec "$HELPER_PROJECT/project.yml" --project "$HELPER_PROJECT" 2>/dev/null
        else
            step_fail "HomeClawHelper.xcodeproj missing and xcodegen not installed. Install with: brew install xcodegen"
        fi
    fi

    # Safety check: verify HomeKit entitlement exists before building.
    # XcodeGen can silently strip it if project.yml is misconfigured.
    if ! grep -q 'com.apple.developer.homekit' "$HELPER_ENTITLEMENTS" 2>/dev/null; then
        step_fail "HomeKit entitlement missing from $HELPER_ENTITLEMENTS — readValue() will silently fail. Check project.yml entitlements.properties."
    fi

    XCODE_SIGN_ARGS=(
        DEVELOPMENT_TEAM="$TEAM_ID"
        MARKETING_VERSION="$MARKETING_VERSION"
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
        ONLY_ACTIVE_ARCH=NO
    )
    if $APP_STORE; then
        XCODE_SIGN_ARGS+=(
            CODE_SIGN_IDENTITY="Apple Distribution"
            CODE_SIGN_STYLE=Manual
        )
    fi

    if xcodebuild -project "$HELPER_PROJECT/HomeClawHelper.xcodeproj" \
        -scheme HomeClawHelper \
        -configuration "$XCODE_CONFIG" \
        -destination 'platform=macOS,variant=Mac Catalyst' \
        -derivedDataPath "$DERIVED_DATA" \
        -allowProvisioningUpdates \
        "${XCODE_SIGN_ARGS[@]}" \
        -quiet 2>/dev/null; then
        step_done
    else
        step_fail "xcodebuild HomeClawHelper failed"
    fi
fi

# Phase 3: Assemble .app bundle
next_step
step "$CURRENT_STEP" "$TOTAL_STEPS" "Assembling app bundle"

# Clean previous bundle
rm -rf "$APP_BUNDLE"

# Create directory structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Helpers"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy Info.plist and inject git-derived version + build number
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"

# Copy app icon
if [[ -f "$PROJECT_ROOT/Resources/HomeClaw.icns" ]]; then
    cp "$PROJECT_ROOT/Resources/HomeClaw.icns" "$APP_BUNDLE/Contents/Resources/HomeClaw.icns"
fi

# Bundle stdio MCP server (self-contained Node.js script for Claude Desktop integration)
MCP_SERVER_JS="$PROJECT_ROOT/mcp-server/dist/server.js"
if [[ ! -f "$MCP_SERVER_JS" ]] && command -v node &>/dev/null && [[ -f "$PROJECT_ROOT/node_modules/.package-lock.json" ]]; then
    # Build if not already built and npm dependencies are installed
    npm run --prefix "$PROJECT_ROOT" build:mcp 2>/dev/null || true
fi
if [[ -f "$MCP_SERVER_JS" ]]; then
    cp "$MCP_SERVER_JS" "$APP_BUNDLE/Contents/Resources/mcp-server.js"
fi

# Bundle OpenClaw plugin files (for one-click install from Settings)
OPENCLAW_SRC="$PROJECT_ROOT/openclaw"
if [[ -d "$OPENCLAW_SRC" ]]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/openclaw"
    cp "$OPENCLAW_SRC/openclaw.plugin.json" "$APP_BUNDLE/Contents/Resources/openclaw/"
    cp "$OPENCLAW_SRC/package.json" "$APP_BUNDLE/Contents/Resources/openclaw/"
    cp -R "$OPENCLAW_SRC/src" "$APP_BUNDLE/Contents/Resources/openclaw/src"
    cp -R "$OPENCLAW_SRC/skills" "$APP_BUNDLE/Contents/Resources/openclaw/skills"
fi

# Copy main executable and CLI binary
cp "$SPM_BUILD_DIR/homeclaw" "$APP_BUNDLE/Contents/MacOS/homeclaw"
cp "$SPM_BUILD_DIR/homeclaw-cli" "$APP_BUNDLE/Contents/MacOS/homeclaw-cli"

# Copy HomeClawHelper.app (entire bundle)
if ! $SKIP_HELPER; then
    if [[ -d "$CATALYST_PRODUCTS/HomeClawHelper.app" ]]; then
        cp -R "$CATALYST_PRODUCTS/HomeClawHelper.app" "$APP_BUNDLE/Contents/Helpers/HomeClawHelper.app"

        # IMPORTANT: Do NOT modify the helper's provisioning profile or re-sign it
        # for development builds. Xcode automatic signing embeds a development
        # provisioning profile that includes the HomeKit entitlement. Re-signing
        # or replacing this profile breaks HomeKit access.
        #
        # Apple restricts com.apple.developer.homekit to App Store distribution
        # only — it CANNOT be included in Developer ID provisioning profiles.
        # See: https://developer.apple.com/forums/thread/699085
        :  # no-op; Xcode's signing is preserved as-is
    else
        step_fail "HomeClawHelper.app not found at $CATALYST_PRODUCTS/HomeClawHelper.app"
    fi
fi

step_done

# Phase 4: Code sign
next_step
step "$CURRENT_STEP" "$TOTAL_STEPS" "Code signing"

SIGNING_IDENTITY=$(detect_signing_identity)

if [[ -n "$SIGNING_IDENTITY" ]]; then
    # Sign inner-to-outer: helper first, then main executable, then outer bundle.
    # IMPORTANT: The outer bundle must NOT use --deep, otherwise it re-signs the
    # helper with the main app's entitlements, stripping com.apple.developer.homekit.

    CODESIGN_FLAGS=(--force --sign "$SIGNING_IDENTITY")

    # HomeClawHelper: Do NOT re-sign. Xcode automatic signing produces a correctly
    # signed helper with HomeKit entitlement + matching provisioning profile.
    # Re-signing would strip the provisioning profile or entitlements.

    codesign "${CODESIGN_FLAGS[@]}" \
        --entitlements "$MAIN_ENTITLEMENTS" \
        "$APP_BUNDLE/Contents/MacOS/homeclaw" 2>/dev/null

    codesign "${CODESIGN_FLAGS[@]}" \
        "$APP_BUNDLE/Contents/MacOS/homeclaw-cli" 2>/dev/null

    codesign "${CODESIGN_FLAGS[@]}" \
        --entitlements "$MAIN_ENTITLEMENTS" \
        "$APP_BUNDLE" 2>/dev/null

    step_done
else
    printf "  (skipped — no identity)\n"
fi

# ─── Summary ────────────────────────────────────────────────────────

echo ""
echo "$(bold "Output:") $APP_BUNDLE"
echo "$(bold "Version:") $MARKETING_VERSION ($BUILD_NUMBER)"
echo ""

# Verify code signature
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    if codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null; then
        echo "  Code signature: valid"
    else
        echo "  Code signature: INVALID (run codesign --verify --deep --strict to diagnose)"
    fi
    echo ""
fi

# ─── Install ────────────────────────────────────────────────────────

if $DO_INSTALL; then
    echo "$(bold "Installing...")"

    # Copy app bundle to /Applications
    if [[ -d "/Applications/$APP_NAME.app" ]]; then
        # Move old version to trash before replacing
        /usr/bin/trash "/Applications/$APP_NAME.app" 2>/dev/null || rm -rf "/Applications/$APP_NAME.app"
    fi
    cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    echo "  Installed: /Applications/$APP_NAME.app"

    # Symlink CLI into Homebrew bin (Apple Silicon: /opt/homebrew/bin, Intel: /usr/local/bin)
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
