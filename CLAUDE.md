# HomeClaw

HomeClaw exposes Apple HomeKit accessories via a CLI tool, plugins for Claude Code and OpenClaw, and a stdio MCP server for Claude Desktop. It uses a split-process architecture to work around Apple's framework restrictions.

## Architecture

```
Claude Code → Plugin (.claude-plugin/) → stdio MCP server (Node.js) ─┐
Claude Desktop → stdio MCP server (Node.js) ─────────────────────────┤
OpenClaw → Plugin (openclaw/) → homeclaw-cli ────────────────────────┤
                                                                     ▼
                                              /tmp/homeclaw.sock (JSON newline-delimited)
                                                                     │
                                              HomeClawHelper (Mac Catalyst UIKit app, headless)
                                                ├── HMHomeManager (requires @MainActor)
                                                ├── HomeKit device discovery & control
                                                └── Unix socket server (GCD-based)

homeclaw (SPM, SwiftUI menu bar app)
  ├── Menu bar UI + Settings window
  ├── HelperManager (launches & monitors HomeClawHelper)
  └── Unix socket client (HomeKitClient)
```

**Why two processes?** `HMHomeManager` requires a UIKit/Catalyst app with the HomeKit entitlement and a valid provisioning profile. Plain Swift CLI/SPM apps cannot access HomeKit. The main app (`homeclaw`) handles UI and helper lifecycle; the helper (`HomeClawHelper`) handles HomeKit. They communicate over a Unix domain socket with JSON newline-delimited messages.

**Note:** The HTTP MCP server (port 9090, bearer token auth) has been disabled. The implementation is preserved in `Sources/homeclaw/MCP/_disabled/` and `Sources/homeclaw/Shared/_disabled/` for reference but is not compiled. All MCP clients now use the stdio server or CLI.

## Project Structure

```
Sources/
  homeclaw/              # Main app (SPM executable)
    App/                 # SwiftUI app entry, AppDelegate, HelperManager
    MCP/                 # (empty — HTTP server moved to _disabled/)
    MCP/_disabled/       # Preserved HTTP MCP server code (not compiled)
    HomeKit/             # HomeKitClient (socket client to helper)
    Views/               # MenuBarView, SettingsView
    Shared/              # AppConfig, Logger
    Shared/_disabled/    # Preserved KeychainManager (not compiled)
  homeclaw-cli/          # CLI tool (SPM executable)
    Commands/            # list, get, set, search, scenes, status, config, device-map
    Commands/_disabled/  # Preserved token command (not compiled)
    SocketClient.swift   # Direct socket communication
  HomeClawHelper/         # Catalyst helper app (Xcode project via XcodeGen)
    HomeKitManager.swift # HMHomeManager wrapper (@MainActor)
    HelperSocketServer.swift  # Unix socket server (GCD)
    CharacteristicMapper.swift # HomeKit type mappings
    AccessoryModel.swift      # JSON serialization models
Resources/               # Info.plist, entitlements, app icons
scripts/build.sh         # Build & install script
mcp-server/              # Node.js stdio MCP server (wraps homeclaw-cli)
openclaw/                # HomeClaw — OpenClaw plugin
  openclaw.plugin.json   # Plugin manifest (configurable binDir)
  src/index.ts           # Plugin entry point
  skills/homekit/        # HomeKit skill definition

App bundle layout (after build):
  Contents/MacOS/homeclaw        # Main app executable
  Contents/MacOS/homeclaw-cli    # Bundled CLI binary
  Contents/Helpers/HomeClawHelper.app  # Catalyst helper
  Contents/Resources/mcp-server.js    # Node.js stdio MCP server
  Contents/Resources/openclaw/        # Bundled OpenClaw plugin files
```

## Build System

Three build systems:
- **SPM** (`swift build`): Builds `homeclaw` and `homeclaw-cli`
- **Xcode** (`xcodebuild`): Builds `HomeClawHelper` as Mac Catalyst app
- **npm** (esbuild): Builds `mcp-server` Node.js MCP server

The `scripts/build.sh` orchestrates SPM + Xcode, assembles the `.app` bundle, and code-signs:

```bash
scripts/build.sh --release --install   # Full build + install to /Applications
scripts/build.sh --debug               # Debug build only
scripts/build.sh --skip-helper         # Skip Catalyst build (faster iteration)
scripts/build.sh --team-id ABCDE12345  # Use a different Apple Developer team
npm run build:mcp                      # Build Node.js MCP server only
```

**npm workspaces**: Root `package.json` defines workspaces for `openclaw` and `mcp-server`. Run `npm install` from the project root.

### XcodeGen

HomeClawHelper uses XcodeGen (`project.yml`) to generate its `.xcodeproj`. The generated `.xcodeproj` is gitignored — regenerate after cloning:
```bash
cd Sources/HomeClawHelper && xcodegen
```

### Development Workflow

```bash
# Build and run from build dir (no install)
scripts/build.sh --debug
open .build/app/HomeClaw.app

# Iterate on SPM code only (skip slow Catalyst build)
scripts/build.sh --debug --skip-helper

# Test HomeKit connection over the socket
echo '{"command":"status"}' | nc -U /tmp/homeclaw.sock
```

## Critical: Entitlements & Distribution

### HomeKit is App Store-only on macOS

Apple restricts `com.apple.developer.homekit` to App Store distribution. It **cannot** be included in Developer ID provisioning profiles. This means:

- **Development signing** (`Apple Development`): Works. Xcode automatic signing creates a provisioning profile with HomeKit.
- **Mac App Store**: Would work, but requires App Store review.
- **Developer ID**: Not supported. HomeKit entitlement cannot be included in Developer ID provisioning profiles.

Reference: [Apple DTS confirmation](https://developer.apple.com/forums/thread/699085) — "The HomeKit entitlement is only available for App Store apps on macOS."

### HomeKit entitlement file

The HomeKit entitlement **must** be in `Sources/HomeClawHelper/HomeClawHelper.entitlements`:
```xml
<key>com.apple.developer.homekit</key>
<true/>
```

**Do NOT remove this.** Without it, `HMHomeManager` silently returns zero homes (even with a valid provisioning profile).

### How the build script handles signing

The build script does **not** re-sign HomeClawHelper. Xcode automatic signing produces a correctly signed helper with the HomeKit entitlement, identity keys, and embedded provisioning profile. Re-signing would strip these.

**Do NOT re-sign the helper.** Xcode embeds identity entitlements (`application-identifier`, `com.apple.developer.team-identifier`) from the provisioning profile. Plain `codesign --entitlements FILE` does a full replacement — signing with just the HomeKit key strips identity keys, causing launchd error 163.

Verify with: `codesign -d --entitlements :- "/Applications/HomeClaw.app/Contents/Helpers/HomeClawHelper.app"`

### For other developers

Developers need their Apple Developer Team ID. The build script reads it from `.env.local` (gitignored), `--team-id` flag, or `HOMEKIT_TEAM_ID` env var:

```bash
# One-time setup: create .env.local from the example
cp .env.local.example .env.local
# Edit .env.local and set your Team ID

# Build
scripts/build.sh --release --install

# Or pass directly
scripts/build.sh --release --install --team-id YOUR_TEAM_ID
```

Xcode automatic signing creates the required provisioning profile for the developer's team. The team ID is passed to `xcodebuild` via `DEVELOPMENT_TEAM`.

## Key Configuration

| Setting | Location | Default |
|---------|----------|---------|
| Device filter | `~/.config/homeclaw/config.json` | `"accessoryFilterMode": "all"` |
| Default home | `~/.config/homeclaw/config.json` | First home |
| Socket path | Hardcoded | `/tmp/homeclaw.sock` |

## MCP Tools

The stdio MCP server (`mcp-server/`) wraps `homeclaw-cli` and exposes tools for home/room/accessory listing, accessory control, scene management, and search. Tool schemas are defined in `lib/schemas.js` and handlers in `lib/handlers/homekit.js`.

## Concurrency Model

- **HomeClawHelper**: `HomeKitManager` is `@MainActor` (required by `HMHomeManager`). Socket server uses GCD with semaphore+ResponseBox to bridge to MainActor.
- **homeclaw**: SwiftUI views use `@State` + `Task` for async data loading.
- Swift 6 strict concurrency is enabled (`SWIFT_STRICT_CONCURRENCY: complete`).

## Debugging

```bash
# Check if helper is running and HomeKit is ready
echo '{"command":"status"}' | nc -U /tmp/homeclaw.sock

# Check entitlements on installed app
codesign -d --entitlements - "/Applications/HomeClaw.app/Contents/Helpers/HomeClawHelper.app"

# Check TCC (privacy) permissions
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT client, auth_value FROM access WHERE service = 'kTCCServiceWillow'"

# View HomeClawHelper logs
log show --predicate 'process == "HomeClawHelper"' --last 10m --style compact
```

If status shows `ready: false` with 0 homes:
1. Verify HomeKit entitlement is embedded (codesign check above)
2. Verify TCC permission granted (auth_value=2)
3. Verify iCloud is signed in with HomeKit data
4. Restart the app after rebuilding

If the helper fails to launch (launchd error 162/163):

The app automatically diagnoses permanent launch failures via `HelperManager.diagnoseLaunchFailure()`, which runs three checks off the main thread:
1. **Provisioning profile exists** — `embedded.provisionprofile` in the helper bundle
2. **Code signature valid** — `codesign --verify --deep --strict`
3. **Device UDID registered** — extracts `ProvisionedDevices` from the profile via `security cms -D` and compares against `system_profiler SPHardwareDataType`

The diagnostic result is stored in `HelperManager.launchDiagnostic` and displayed in the menu bar under "Helper Not Running". When a permanent issue is detected, auto-restart is skipped (it would never succeed). Manual restart clears the diagnostic.

For manual diagnosis:
1. Verify identity entitlements are present: `codesign -d --entitlements :- .../HomeClawHelper.app` should show `application-identifier` and `com.apple.developer.team-identifier`
2. Verify `embedded.provisionprofile` exists in the helper bundle — Mac Catalyst apps with restricted entitlements require it
3. Ensure the provisioning profile matches the signing identity (Apple Development profile + Apple Development signing, NOT mixed with Developer ID)
4. Check AMFI logs: `/usr/bin/log show --predicate 'eventMessage CONTAINS "HomeKit"' --last 2m` — look for "unsatisfied entitlements" or "no eligible provisioning profiles"

## Code Style

- Swift 6 with strict concurrency
- `@MainActor` for all HomeKit API interactions
- `os.Logger` via `AppLogger` (main app) and `HelperLogger` (helper)
- JSON communication over Unix domain sockets (newline-delimited)

## CI

GitHub Actions (`.github/workflows/tests.yml`) runs on `macos-26`:
- Builds `homeclaw` and `homeclaw-cli` via SPM
- Builds `mcp-server` (Node.js) on ubuntu-latest
- HomeClawHelper is NOT built in CI (requires signing identity + provisioning)
