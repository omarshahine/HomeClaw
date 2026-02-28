<p align="center"><img src="docs/images/homeclaw-icon.png" width="200" alt="HomeClaw icon"></p>

# HomeClaw

Control your Apple HomeKit smart home from AI assistants, the terminal, and automation tools.

HomeClaw exposes your HomeKit accessories through a **command-line tool**, a **stdio MCP server**, and plugins for **Claude Code** and **OpenClaw**. It runs as a lightweight macOS menu bar app.

## Why HomeClaw?

Apple HomeKit has no public API, no CLI, and no way to integrate with AI assistants or automation pipelines. HomeClaw bridges that gap with a Mac Catalyst app that talks to HomeKit on your behalf and exposes a clean API surface.

- Ask Claude or OpenClaw to "turn off all the lights" or "set the thermostat to 72"
- Script your smart home from the terminal
- Build automations that go beyond what the Home app offers
- Search and control devices by name, room, category, or semantic type

## Architecture

```
Claude Code --> Plugin (.claude-plugin/) --> stdio MCP server (Node.js) --+
Claude Desktop --> stdio MCP server (Node.js) ----------------------------+
OpenClaw --> Plugin (openclaw/) --> homeclaw-cli --------------------------+
                                                                          v
                                               Unix socket (JSON newline-delimited)
                                                                          |
                                               HomeClaw (Mac Catalyst app)
                                                 +-- HomeKitManager (direct, in-process)
                                                 +-- SocketServer (for CLI/MCP clients)
                                                 +-- macOSBridge.bundle (NSStatusItem menu bar)
```

**Single-process design.** Apple's `HMHomeManager` requires a UIKit/Catalyst app with the HomeKit entitlement. By making the entire app Catalyst, HomeKit access is direct (no IPC), signing is unified (single archive), and App Store submission is clean. The `macOSBridge` plugin bundle provides the native macOS menu bar via `NSStatusItem`.

## Install

### TestFlight (Recommended)

The easiest way to install HomeClaw is via TestFlight:

1. **[Join the TestFlight Beta](https://testflight.apple.com/join/zjSnz8eK)**
2. Install HomeClaw from TestFlight
3. Launch the app -- grant HomeKit access when prompted
4. The menu bar icon appears. Click it to see your connected homes.

TestFlight builds are signed for App Store distribution, so HomeKit works without any developer account setup.

Once running, set up your AI integrations:

- **[Claude Desktop](#connecting-an-mcp-client)** -- one-click install from Settings > Integrations, or add the MCP server config manually
- **[Claude Code](#using-with-claude-code)** -- install the plugin from GitHub
- **[OpenClaw](#using-with-openclaw)** -- one-click install from Settings > Integrations, or set up manually

### Build from Source

<details>
<summary>Prerequisites and setup for building from source</summary>

#### Prerequisites

- macOS 26 (Tahoe) or later
- Xcode 26+ with Swift 6.2
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Node.js 20+ (for the MCP server wrapper)
- **Apple Developer account** with HomeKit capability enabled

> **Why is a developer account required?** Apple does not provide a public HomeKit API for macOS. The only way to access HomeKit is through `HMHomeManager`, which requires the `com.apple.developer.homekit` entitlement and a provisioning profile that covers your Mac's hardware UDID. Apple restricts this entitlement to development signing and App Store distribution -- it cannot be included in Developer ID (notarized) builds. This means every Mac that runs HomeClaw must be registered as a development device in your Apple Developer portal, and the app must be built with your team's signing identity. There is no way around this; it's an Apple platform restriction, not a HomeClaw limitation.

#### Setup

```bash
git clone https://github.com/omarshahine/HomeClaw.git
cd HomeClaw

# Configure your Apple Developer Team ID (one-time setup)
echo "HOMEKIT_TEAM_ID=YOUR_TEAM_ID" > .env.local

# Install Node.js dependencies
npm install

# Build everything and install
scripts/build.sh --release --install
```

Find your Team ID at [developer.apple.com/account](https://developer.apple.com/account) under Membership Details.

Launch from `/Applications` or: `open "/Applications/HomeClaw.app"`

On first launch, grant HomeKit access when prompted. The menu bar icon appears -- click it to see your connected homes.

> **Note:** Apple restricts the HomeKit entitlement to development signing and App Store distribution. Developer ID builds cannot access HomeKit. See [Why Development Signing?](#why-development-signing) for details.

</details>

## MCP Tools

The stdio MCP server wraps `homeclaw-cli` and exposes these tools:

| Tool | Description |
|------|-------------|
| `homekit_status` | Check bridge connectivity and accessory count |
| `homekit_accessories` | List, get details, search, or control accessories |
| `homekit_rooms` | List rooms and their accessories |
| `homekit_scenes` | List or trigger scenes |
| `homekit_device_map` | LLM-optimized device map with semantic types and aliases |
| `homekit_events` | Query recent HomeKit events (characteristic changes, scene triggers, control actions) |
| `homekit_config` | View or update configuration (set active home, filtering) |

### Connecting an MCP Client

Any MCP-compatible client can connect via the **stdio server**, which wraps `homeclaw-cli` and requires no authentication (the HomeClaw app must be running for the socket). Add this to your MCP client config (e.g. `claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "homeclaw": {
      "command": "node",
      "args": ["/Applications/HomeClaw.app/Contents/Resources/mcp-server.js"]
    }
  }
}
```

The `mcp-server.js` is bundled inside the app. You can also use the Integrations tab in Settings to install this automatically.

## CLI

The `homeclaw-cli` command-line tool communicates directly over the Unix domain socket. All read commands support `--json` for machine-readable output.

```bash
# List accessories
homeclaw-cli list
homeclaw-cli list --room "Kitchen"
homeclaw-cli list --category thermostat

# Control devices
homeclaw-cli set "Living Room Light" brightness 75
homeclaw-cli set "Front Door Lock" lock_target_state locked
homeclaw-cli set "Thermostat" target_temperature 72

# Get detailed device info
homeclaw-cli get "Kitchen Light" --json

# Search across all homes
homeclaw-cli search "bedroom" --category lightbulb

# Scenes
homeclaw-cli scenes
homeclaw-cli trigger "Good Night"

# LLM-optimized device map
homeclaw-cli device-map

# Status and configuration
homeclaw-cli status
homeclaw-cli config --default-home "Main House"
homeclaw-cli config --filter-mode allowlist
homeclaw-cli config --list-devices

# Event log
homeclaw-cli events                         # Recent events (last 50)
homeclaw-cli events --since 1h              # Events from the last hour
homeclaw-cli events --since 2d --json       # Last 2 days, JSON output
homeclaw-cli events --type scene_triggered  # Filter by event type

# Webhook configuration
homeclaw-cli config --webhook-url "http://127.0.0.1:18789/hooks/wake"
homeclaw-cli config --webhook-token "your-secret-token"
homeclaw-cli config --webhook-enabled true
```

## Using with Claude Code

HomeClaw integrates with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) as a **plugin** that provides MCP tools and a HomeKit skill for richer natural language understanding.

### Installing the Plugin

Install from a local clone or directly from GitHub.

**From a local clone:**

```bash
# Clone if you haven't already
git clone https://github.com/omarshahine/HomeClaw.git ~/GitHub/HomeClaw

# Inside Claude Code, register the marketplace and install
/plugin marketplace add ~/GitHub/HomeClaw
/plugin install homeclaw@homeclaw
```

**From GitHub (no local clone needed):**

```bash
# Inside Claude Code, add the GitHub repo as a marketplace
/plugin marketplace add https://github.com/omarshahine/HomeClaw

# Install the plugin
/plugin install homeclaw@homeclaw
```

After installing, restart Claude Code. Then just ask:

> "Turn on the kitchen lights and set them to 50% brightness"
> "Lock all the doors"
> "What's the thermostat set to?"
> "Run the movie time scene"
> "Which lights are on in the living room?"

### Verifying the Connection

After installing, verify Claude can reach HomeKit:

```bash
# Check MCP server status inside Claude Code
/mcp
```

## Using with OpenClaw

HomeClaw includes an [OpenClaw](https://openclaw.ai) plugin that registers a HomeKit skill on the gateway. The skill calls `homeclaw-cli` by name, so it must be in your PATH.

### Same-Mac Install (Recommended)

If HomeClaw and OpenClaw run on the same Mac, use the one-click installer:

1. Open **Settings > Integrations** and click **Install** in the OpenClaw section.

This handles all four steps automatically: installs the plugin, enables it, symlinks `homeclaw-cli` into your PATH, and restarts the gateway.

Or from the terminal:

```bash
# 1. Install the plugin from the bundled files
openclaw plugins install "/Applications/HomeClaw.app/Contents/Resources/openclaw/"
openclaw plugins enable homeclaw

# 2. Symlink the CLI into PATH (the skill calls homeclaw-cli by name)
# Apple Silicon (M1/M2/M3/M4):
ln -sf '/Applications/HomeClaw.app/Contents/MacOS/homeclaw-cli' /opt/homebrew/bin/homeclaw-cli
# Intel:
ln -sf '/Applications/HomeClaw.app/Contents/MacOS/homeclaw-cli' /usr/local/bin/homeclaw-cli

# 3. Restart the gateway to load the plugin
openclaw gateway restart
```

### Remote Gateway

If OpenClaw runs on a different machine:

```bash
# Clone the repo on the gateway
git clone https://github.com/omarshahine/HomeClaw.git ~/GitHub/HomeClaw

# Install the plugin
openclaw plugins install ~/GitHub/HomeClaw/openclaw
openclaw plugins enable homeclaw

# Symlink the CLI into PATH
ln -sf /path/to/homeclaw-cli /opt/homebrew/bin/homeclaw-cli

# Restart the gateway
openclaw gateway restart
```

> **Note:** The `homeclaw-cli` binary must be accessible from the gateway (in PATH), and the HomeClaw app must be running on the same Mac (connected via Unix socket).

## Supported Accessories

HomeClaw supports the full range of HomeKit accessory categories:

| Category | Controllable Characteristics |
|----------|------------------------------|
| **Lights** | power, brightness (0-100), hue (0-360), saturation (0-100), color temperature (140-500 mireds) |
| **Thermostats** | target temperature, HVAC mode (off/heat/cool/auto), target humidity |
| **Locks** | lock/unlock (accepts `locked`, `unlocked`, `0`, `1`) |
| **Doors & Garage Doors** | open/close, obstruction detection (read-only) |
| **Fans** | active, rotation speed, rotation direction, swing mode |
| **Window Coverings** | target position (0-100%) |
| **Switches & Outlets** | power on/off |
| **Sensors** | motion, contact, temperature, humidity, light level, battery (all read-only) |
| **Scenes** | trigger by name or UUID |

## Menu Bar App

The menu bar provides at-a-glance status and quick actions:

- **HomeKit connection status** -- shows home names when connected, or error states with reasons
- **Launch at Login** toggle
- **Settings** link and **Quit**

## Settings

Five configuration tabs accessible from the menu bar:

| Tab | Features |
|-----|----------|
| **HomeKit** | Connection status, home list with accessory and room counts, active home selector |
| **Devices** | Filter mode (all/allowlist), per-device toggles grouped by room, search, bulk select/deselect |
| **Event Log** | Enable/disable event logging, configure file rotation (size limit + backup count), view storage stats, purge logs, reveal in Finder |
| **Webhook** | Configure webhook endpoint (URL + bearer token), select which scenes and accessories trigger webhooks using checkboxes grouped by room |
| **Integrations** | One-click install for Claude Desktop, Claude Code plugin detection, OpenClaw gateway setup |

### HomeKit

View connection status, browse your homes, and select which home is active for all MCP and CLI commands.

<p align="center"><img src="docs/images/settings-homekit.png" width="500" alt="HomeKit settings tab"></p>

### Devices

Control which accessories are exposed to MCP clients and the CLI. Switch between **All Accessories** (everything visible) and **Selected Only** (allowlist mode). Accessories are grouped by room with a search filter and room-level toggles for quick bulk selection.

<p align="center"><img src="docs/images/settings-devices.png" width="500" alt="Devices settings tab"></p>

### Integrations

Install and manage connections to AI assistants. The app detects existing configurations and guides you through setup:

- **Claude Desktop** -- one-click install of the bundled stdio MCP server (requires Node.js)
- **Claude Code** -- detects the installed plugin (`homeclaw@homeclaw`)
- **OpenClaw** -- detects plugin configuration on the remote gateway and provides setup instructions

<p align="center"><img src="docs/images/settings-integrations.png" width="500" alt="Integrations settings tab"></p>

## Event Log

HomeClaw records all HomeKit events to a JSONL file in `~/Library/Application Support/HomeClaw/events.jsonl`. Events include characteristic changes (a light turned on), scene triggers, and control actions from the CLI or MCP.

### Configuration

Open **Settings > Event Log** to configure:

- **Enable/disable** event logging
- **Max file size** (10-500 MB) -- when the log reaches this size, it's rotated
- **Rotated backups** (0-10) -- how many old log files to keep before deleting the oldest
- **Purge** -- delete all event log files
- **Show in Finder** -- reveal the log directory

Or configure via CLI:

```bash
homeclaw-cli events                         # Show recent events
homeclaw-cli events --since 1h              # Last hour
homeclaw-cli events --type characteristic_change  # Filter by type
homeclaw-cli events --limit 200 --json      # JSON output
```

Event types: `characteristic_change`, `scene_triggered`, `accessory_controlled`, `homes_updated`

The `--since` flag accepts ISO 8601 timestamps or duration shorthand: `1h`, `30m`, `2d`.

## Webhook

HomeClaw can push events to an HTTP endpoint (designed for [OpenClaw](https://openclaw.ai)'s `/hooks/wake` format). When a webhook is configured and specific scenes or accessories are selected, HomeClaw POSTs a JSON payload on each matching event.

### Setup

1. Open **Settings > Webhook**
2. Toggle **Enable Webhook**
3. Enter the webhook URL (e.g. `http://127.0.0.1:18789/hooks/wake`)
4. Click **Generate** to create a secure bearer token (or enter your own)
5. Check the scenes and accessories you want to trigger webhooks

Or configure via CLI (useful for automated setup from OpenClaw):

```bash
homeclaw-cli config --webhook-url "http://127.0.0.1:18789/hooks/wake" \
                    --webhook-token "your-secret-token" \
                    --webhook-enabled true
```

### Payload Format

```json
{
  "text": "HomeKit: Kitchen Light power set to true",
  "mode": "now"
}
```

Authentication uses `Authorization: Bearer <token>`. The webhook includes a circuit breaker -- after 5 consecutive failures, delivery pauses for 60 seconds before retrying.

## Device Filtering

Use the [Devices tab](#devices) in Settings or the CLI to control which accessories are exposed:

```bash
homeclaw-cli config --filter-mode allowlist
homeclaw-cli config --allow-accessories "uuid1,uuid2,uuid3"
homeclaw-cli config --list-devices  # shows allowed/filtered status
```

## Building

The build script uses XcodeGen to generate the Xcode project and `xcodebuild` to compile all targets (HomeClaw Catalyst app, macOSBridge bundle, homeclaw-cli tool):

```bash
# Full release build + install to /Applications
scripts/build.sh --release --install

# Override team ID on the command line
scripts/build.sh --release --install --team-id ABCDE12345

# Debug build (faster)
scripts/build.sh --debug

# Clean build artifacts first
scripts/build.sh --clean
```

Your Apple Developer Team ID is required, provided via `.env.local`, `--team-id`, or the `HOMEKIT_TEAM_ID` environment variable.

### Archiving for App Store / TestFlight

```bash
scripts/archive.sh
# Then open in Xcode Organizer to distribute:
open '.build/archives/HomeClaw.xcarchive'
```

### Version Bumping

Version is derived from git tags at build time. To release a new version:

```bash
scripts/bump-version.sh 0.2.0   # Updates source files + prints tag commands
npm run build:mcp                # Rebuild MCP server with new version
git add -A && git commit -m "Bump version to 0.2.0"
git tag -a v0.2.0 -m "HomeClaw v0.2.0"
git push && git push origin v0.2.0
```

### Installing on Additional Macs

Development-signed builds are tied to registered devices. To run HomeClaw on another Mac:

1. **Get the target Mac's Provisioning UDID** -- on that Mac, run:
   ```bash
   system_profiler SPHardwareDataType | grep "Provisioning UDID"
   ```

2. **Register the device** at [developer.apple.com/account/resources/devices/add](https://developer.apple.com/account/resources/devices/add):
   - **Platform**: macOS
   - **Device Name**: a descriptive name (e.g. "Living Room MacBook Air")
   - **Device ID**: the Provisioning UDID from step 1

3. **Rebuild** on your development machine (Xcode regenerates the provisioning profile to include the new device):
   ```bash
   scripts/build.sh --release --install --clean
   ```

4. **Copy** `/Applications/HomeClaw.app` to the target Mac (AirDrop, USB, network share, etc.)

5. **Grant HomeKit access** on first launch when prompted.

> **Note:** The target Mac must be signed into iCloud with an account that has HomeKit home data. HomeKit homes are tied to iCloud accounts, not to the app.

### Why Development Signing?

Apple restricts the `com.apple.developer.homekit` entitlement to **development signing** and **Mac App Store** distribution. It cannot be included in Developer ID provisioning profiles. A Developer ID build would pass Gatekeeper but have no HomeKit access (`HMHomeManager` returns zero homes). This is an [Apple platform restriction](https://developer.apple.com/forums/thread/699085), not a bug.

## Project Structure

```
Sources/
  homeclaw/                Unified Catalyst app (Xcode target via XcodeGen)
    App/                   UIApplicationDelegate entry point, scene delegates
    Bridge/                BridgeProtocols.swift (Mac2iOS, iOS2Mac)
    HomeKit/               HomeKitManager, SocketServer, CharacteristicMapper,
                           AccessoryModel, DeviceMap, CharacteristicCache,
                           HomeEventLogger
    Views/                 SettingsView, IntegrationsSettingsView
    Shared/                AppConfig, AppLogger, HomeClawConfig
  macOSBridge/             AppKit bundle (NSStatusItem menu bar)
    MacOSController.swift  NSStatusItem + NSMenu via iOS2Mac protocol
    Info.plist             NSPrincipalClass: MacOSController
  homeclaw-cli/            CLI tool (SPM executable + Xcode target)
    Commands/              list, get, set, search, scenes, status, config, device-map, events
    SocketClient.swift     Direct socket communication
Resources/                 Info.plist, entitlements, app icons
scripts/
  build.sh                 Build, sign, and install
  archive.sh               Archive for App Store / TestFlight
  bump-version.sh          Update version across source files
mcp-server/                Node.js stdio MCP server (wraps homeclaw-cli)
openclaw/                  OpenClaw plugin (HomeClaw)
  skills/homekit/          HomeKit skill with full characteristic reference

App bundle layout (after build):
  Contents/MacOS/HomeClaw              Catalyst app executable
  Contents/MacOS/homeclaw-cli          Bundled CLI binary
  Contents/Resources/macOSBridge.bundle  AppKit menu bar plugin
  Contents/Resources/mcp-server.js       Node.js stdio MCP server
  Contents/Resources/openclaw/           Bundled OpenClaw plugin files
```

## Debugging

```bash
# Check if HomeClaw is running and HomeKit is ready
echo '{"command":"status"}' | nc -U ~/Library/Group\ Containers/group.com.shahine.homeclaw/homeclaw.sock

# Or via the CLI
homeclaw-cli status

# Verify HomeKit entitlement on installed app
codesign -d --entitlements :- "/Applications/HomeClaw.app"

# View HomeClaw logs
log show --predicate 'process == "HomeClaw"' --last 10m --style compact

# Check TCC (privacy) permissions
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT client, auth_value FROM access WHERE service = 'kTCCServiceWillow'"
```

| Symptom | Cause | Fix |
|---------|-------|-----|
| 0 homes, `ready: false` | Missing HomeKit entitlement | Verify with `codesign -d --entitlements` |
| All characteristic values `nil` | Accessory unreachable | Check device power and network |
| "HomeKit Unavailable" in menu | iCloud not signed in | Sign into iCloud with HomeKit data |
| CLI crashes with SIGTRAP | Missing bundle ID in sandbox | Rebuild with `CREATE_INFOPLIST_SECTION_IN_BINARY: YES` |

## Tech Stack

- **Swift 6** with strict concurrency (`@MainActor`, `actor` isolation)
- **Mac Catalyst** (UIKit) for HomeKit framework access
- **AppKit** (via macOSBridge bundle) for native menu bar
- **[Swift Argument Parser](https://github.com/apple/swift-argument-parser)** for CLI
- **Node.js** + **[@modelcontextprotocol/sdk](https://github.com/modelcontextprotocol/typescript-sdk)** for stdio MCP server
- **XcodeGen** for Xcode project generation
- **GCD** + Unix domain sockets for CLI/MCP communication

## FAQ

### `spctl --assess` says "rejected" -- is that a problem?

No. `spctl` checks Gatekeeper, which only trusts Developer ID and App Store signing. HomeClaw uses **development signing** (required for HomeKit on macOS), so Gatekeeper will always reject it. This is expected and doesn't prevent the app from running -- AMFI handles development-signed apps separately via the embedded provisioning profile.

### Can I use a different Apple ID for HomeKit than my developer account?

Yes. The two accounts serve completely different purposes:

- **Apple Developer account** -- only matters at build time. Xcode uses it to create the provisioning profile and sign the code.
- **iCloud account** (on the Mac running HomeClaw) -- determines which HomeKit homes appear. This is the account linked to your Home app data.

These are independent. You can build HomeClaw with your developer account and run it on a Mac signed into a completely different iCloud account that has HomeKit homes. The HomeKit data follows the iCloud account, not the signing identity.

### When should I use `--clean`?

Use `scripts/build.sh --clean` when:

- Switching Apple Developer Team IDs
- After major Xcode version updates
- Build fails with signing or entitlement errors
- You see code signature errors after rebuilding

The `--clean` flag removes all build artifacts before building fresh.

### HomeKit shows 0 homes

The app is running but can't see any HomeKit data. Check in order:

1. **iCloud signed in?** HomeKit data lives in iCloud. Open System Settings > Apple Account and verify.
2. **HomeKit entitlement present?** Run:
   ```bash
   codesign -d --entitlements :- "/Applications/HomeClaw.app"
   ```
   You should see `com.apple.developer.homekit` -> `true`.
3. **TCC permission granted?** On first launch, macOS asks for HomeKit access. If you denied it, re-grant in System Settings > Privacy & Security > HomeKit.
4. **Using Developer ID signing?** Only development signing supports the HomeKit entitlement. See [Why Development Signing?](#why-development-signing).

### How do I install on another Mac?

Development-signed apps are tied to registered devices. See [Installing on Additional Macs](#installing-on-additional-macs) for the full walkthrough.

### How do I see what's happening?

```bash
# HomeClaw app logs
log show --predicate 'process == "HomeClaw"' --last 10m --style compact

# Check HomeKit status directly over the socket
homeclaw-cli status

# Verify code signature and entitlements
codesign -d --entitlements :- "/Applications/HomeClaw.app"
```

## License

[MIT](LICENSE) -- Copyright (c) 2025 Omar Shahine
