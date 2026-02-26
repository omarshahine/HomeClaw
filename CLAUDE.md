# HomeClaw

HomeClaw exposes Apple HomeKit accessories via a CLI tool, plugins for Claude Code and OpenClaw, and a stdio MCP server for Claude Desktop. It uses a unified Mac Catalyst architecture with an AppKit bridge bundle for the macOS menu bar.

## Architecture

```
Claude Code → Plugin (.claude-plugin/) → stdio MCP server (Node.js) ─┐
Claude Desktop → stdio MCP server (Node.js) ─────────────────────────┤
OpenClaw → Plugin (openclaw/) → homeclaw-cli ────────────────────────┤
                                                                     ▼
                                              /tmp/homeclaw.sock (JSON newline-delimited)
                                                                     │
                                              HomeClaw (Mac Catalyst UIKit app)
                                                ├── HomeKitManager (direct, in-process)
                                                ├── SocketServer (for CLI/MCP clients)
                                                └── macOSBridge.bundle (NSStatusItem menu bar)
```

**Single-process design.** `HMHomeManager` requires a UIKit/Catalyst app with the HomeKit entitlement. By making the entire app Catalyst, HomeKit access is direct (no IPC), signing is unified (single archive), and App Store submission is clean. The macOSBridge plugin bundle provides the native macOS menu bar via `NSStatusItem`.

**Note:** The HTTP MCP server (port 9090, bearer token auth) has been disabled. The implementation is preserved in `Sources/homeclaw/MCP/_disabled/` and `Sources/homeclaw/Shared/_disabled/` for reference but is not compiled. All MCP clients now use the stdio server or CLI.

## Project Structure

```
Sources/
  homeclaw/              # Unified Catalyst app (Xcode target via XcodeGen)
    App/                 # UIApplicationDelegate entry point, scene delegates
    Bridge/              # BridgeProtocols.swift (Mac2iOS, iOS2Mac)
    MCP/_disabled/       # Preserved HTTP MCP server code (not compiled)
    HomeKit/             # HomeKitManager, SocketServer, CharacteristicMapper,
                         # AccessoryModel, DeviceMap, CharacteristicCache
    Views/               # SettingsView, IntegrationsSettingsView
    Shared/              # AppConfig, AppLogger, HomeClawConfig
    Shared/_disabled/    # Preserved KeychainManager (not compiled)
  macOSBridge/           # AppKit bundle (NSStatusItem menu bar)
    MacOSController.swift  # NSStatusItem + NSMenu
    Info.plist           # NSPrincipalClass: MacOSController
  homeclaw-cli/          # CLI tool (SPM executable + Xcode target)
    Commands/            # list, get, set, search, scenes, status, config, device-map
    Commands/_disabled/  # Preserved token command (not compiled)
    SocketClient.swift   # Direct socket communication
Resources/               # Info.plist, entitlements, app icons
scripts/build.sh         # Build & install script
scripts/archive.sh       # Archive for App Store / TestFlight
mcp-server/              # Node.js stdio MCP server (wraps homeclaw-cli)
openclaw/                # HomeClaw — OpenClaw plugin
  openclaw.plugin.json   # Plugin manifest (configurable binDir)
  src/index.ts           # Plugin entry point
  skills/homekit/        # HomeKit skill definition

App bundle layout (after build):
  Contents/MacOS/HomeClaw          # Catalyst app executable
  Contents/MacOS/homeclaw-cli      # Bundled CLI binary
  Contents/PlugIns/macOSBridge.bundle  # AppKit menu bar plugin
  Contents/Resources/mcp-server.js     # Node.js stdio MCP server
  Contents/Resources/openclaw/         # Bundled OpenClaw plugin files
```

## Build System

Two build systems:
- **Xcode** (`xcodebuild`): Builds `HomeClaw` (Catalyst), `macOSBridge` (macOS bundle), and `homeclaw-cli` (macOS tool)
- **npm** (esbuild): Builds `mcp-server` Node.js MCP server

SPM (`Package.swift`) is retained for CI — it builds `homeclaw-cli` only. The main app is Catalyst-only (Xcode).

The `scripts/build.sh` orchestrates xcodegen + xcodebuild:

```bash
scripts/build.sh --release --install   # Full build + install to /Applications
scripts/build.sh --debug               # Debug build only
scripts/build.sh --team-id ABCDE12345  # Use a different Apple Developer team
npm run build:mcp                      # Build Node.js MCP server only
```

**npm workspaces**: Root `package.json` defines workspaces for `openclaw` and `mcp-server`. Run `npm install` from the project root.

### XcodeGen

The root `project.yml` defines all three targets (HomeClaw, macOSBridge, homeclaw-cli). The generated `.xcodeproj` is gitignored — regenerate after cloning:
```bash
xcodegen generate
```

### Development Workflow

```bash
# Generate project + build debug
scripts/build.sh --debug

# Open in Xcode for debugging
xcodegen generate && open HomeClaw.xcodeproj

# Test HomeKit connection over the socket
echo '{"command":"status"}' | nc -U /tmp/homeclaw.sock
```

## Critical: Entitlements & Distribution

### HomeKit is App Store-only on macOS

Apple restricts `com.apple.developer.homekit` to App Store distribution. It **cannot** be included in Developer ID provisioning profiles. This means:

- **Development signing** (`Apple Development`): Works. Xcode automatic signing creates a provisioning profile with HomeKit.
- **Mac App Store**: Works. Single Catalyst app with unified signing.
- **Developer ID**: Not supported. HomeKit entitlement cannot be included in Developer ID provisioning profiles.

Reference: [Apple DTS confirmation](https://developer.apple.com/forums/thread/699085) — "The HomeKit entitlement is only available for App Store apps on macOS."

### HomeKit entitlement file

The HomeKit entitlement is in `Resources/HomeClaw.entitlements`:
```xml
<key>com.apple.developer.homekit</key>
<true/>
```

**Do NOT remove this.** Without it, `HMHomeManager` silently returns zero homes (even with a valid provisioning profile).

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
| Device filter | `~/Library/Application Support/HomeClaw/config.json` | `"accessoryFilterMode": "all"` |
| Default home | `~/Library/Application Support/HomeClaw/config.json` | First home |
| Socket path | App Group container or `/tmp/homeclaw.sock` | Auto-detected |

## MCP Tools

The stdio MCP server (`mcp-server/`) wraps `homeclaw-cli` and exposes tools for home/room/accessory listing, accessory control, scene management, and search. Tool schemas are defined in `lib/schemas.js` and handlers in `lib/handlers/homekit.js`.

## Concurrency Model

- `HomeKitManager` is `@MainActor` (required by `HMHomeManager`). Socket server uses GCD with semaphore+ResponseBox to bridge to MainActor.
- Settings views use `@State` + `Task` for async data loading.
- Swift 6 strict concurrency is enabled (`SWIFT_STRICT_CONCURRENCY: complete`).

## Debugging

```bash
# Check HomeKit status via socket
echo '{"command":"status"}' | nc -U /tmp/homeclaw.sock

# Check entitlements on installed app
codesign -d --entitlements :- "/Applications/HomeClaw.app"

# Check TCC (privacy) permissions
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT client, auth_value FROM access WHERE service = 'kTCCServiceWillow'"

# View HomeClaw logs
log show --predicate 'process == "HomeClaw"' --last 10m --style compact
```

If status shows `ready: false` with 0 homes:
1. Verify HomeKit entitlement is embedded (codesign check above)
2. Verify TCC permission granted (auth_value=2)
3. Verify iCloud is signed in with HomeKit data
4. Restart the app after rebuilding

## Code Style

- Swift 6 with strict concurrency
- `@MainActor` for all HomeKit API interactions
- `os.Logger` via `AppLogger` (categories: homekit, app, socket, cli)
- JSON communication over Unix domain sockets (newline-delimited)

## CI

GitHub Actions (`.github/workflows/tests.yml`) runs on `macos-26`:
- Builds `homeclaw-cli` via SPM
- Builds `mcp-server` (Node.js)
- HomeClaw Catalyst app is NOT built in CI (requires signing identity + provisioning)
