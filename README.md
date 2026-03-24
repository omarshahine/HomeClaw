# HomeClaw

HomeClaw brings Apple HomeKit to AI assistants. It exposes your smart home accessories via a CLI, MCP server, and plugins for [Claude Code](https://claude.com/claude-code) and [OpenClaw](https://openclaw.ai).

Built as a Mac Catalyst app with a native macOS menu bar, HomeClaw talks directly to HomeKit and serves requests over a Unix domain socket.

## What Can It Do?

- **Control accessories**: lights, locks, thermostats, blinds, fans, outlets, scenes
- **Search and discover**: find devices by name, room, category, or manufacturer
- **Manage your home**: rename accessories, create rooms and zones, assign devices
- **Program buttons**: create automations for programmable switches (Aqara, Hue, etc.) with inline actions or scene triggers
- **Monitor events**: real-time event logging with webhook push to OpenClaw agents
- **LLM-optimized output**: device maps, semantic types, and agent-friendly JSON

## Quick Start

```bash
# Clone and set up
git clone https://github.com/omarshahine/HomeClaw.git
cd HomeClaw
npm install

# One-time: set your Apple Developer Team ID
cp .env.local.example .env.local
# Edit .env.local with your Team ID

# Build, install, and launch
scripts/build.sh --release --install
open /Applications/HomeClaw.app
```

HomeClaw requires the HomeKit entitlement, which Apple restricts to App Store distribution on macOS. Development signing works fine for local builds.

## CLI Examples

```bash
# Check status
homeclaw-cli status

# Search for devices
homeclaw-cli search "kitchen"

# Control a light
homeclaw-cli set "Kitchen Overhead" power true
homeclaw-cli set "Kitchen Overhead" brightness 75

# Run a scene
homeclaw-cli trigger "Good Night"

# Get the full device map (LLM-optimized)
homeclaw-cli device-map --format agent
```

## Button Programming

HomeClaw can create HomeKit automations for programmable switches, something typically only possible through the Home app UI.

```bash
# Inline actions (creates a scene named after the automation)
homeclaw-cli automations create \
  --name "Office Light On" \
  --accessory "Office Button" \
  --action "Key Light:power:true" \
  --action "Key Light:brightness:50" \
  --press single --service-index 1

# Scene-based (triggers an existing scene)
homeclaw-cli automations create \
  --name "Movie Mode" \
  --accessory "Remote Button" \
  --scene "Movie Time" \
  --press single

# List all automations
homeclaw-cli automations list

# Preview before creating
homeclaw-cli automations create --name "Test" --accessory "Button" \
  --action "Light:power:true" --dry-run
```

**Inline vs scene:** Use `--action` for simple button-to-device mappings. This creates a scene named after the automation. Use `--scene` to trigger an existing scene instead. Note: Apple's Home app uses a private API for hidden automation-only action sets; inline actions created via HomeClaw will appear as visible scenes in the Home app.

**Button modes:** Some buttons (like Aqara AR009) support fast mode (2 buttons, single press each, instant response) or multi-event mode (1 button, single/double/long press, ~300ms delay). Use `--service-index` to target a specific button in fast mode.

## Architecture

```
Claude Code / Claude Desktop / OpenClaw
        |
        v
  homeclaw-cli / MCP server (Node.js stdio)
        |
        v
  Unix domain socket (JSON newline-delimited)
        |
        v
  HomeClaw.app (Mac Catalyst)
    +-- HomeKitManager (direct HMHomeManager access)
    +-- SocketServer (GCD, bridges to @MainActor)
    +-- macOSBridge.bundle (NSStatusItem menu bar)
```

**Why Catalyst?** `HMHomeManager` requires a UIKit app with the HomeKit entitlement. Mac Catalyst gives us UIKit for HomeKit, AppKit for the menu bar (via a plugin bundle), and a single archive for App Store distribution.

## Plugin Support

| Platform | Plugin Type | How It Works |
|----------|-------------|--------------|
| Claude Code | `.claude-plugin/` | stdio MCP server wrapping homeclaw-cli |
| Claude Desktop | MCP server | Same stdio MCP server |
| OpenClaw | `openclaw/` | Direct homeclaw-cli invocation |

## MCP Tools

| Tool | Description |
|------|-------------|
| `homekit_status` | Bridge connectivity and health |
| `homekit_accessories` | List, search, get details, control devices |
| `homekit_rooms` | Room listing with accessories |
| `homekit_scenes` | List, inspect, trigger, import, delete scenes |
| `homekit_automations` | Create, list, delete, enable/disable automations |
| `homekit_device_map` | LLM-optimized device map with semantic types |
| `homekit_events` | Query recent HomeKit events |
| `homekit_webhook` | Webhook configuration and health |
| `homekit_config` | Bridge configuration |

## Requirements

- macOS 14+ (Sonoma or later)
- Apple Developer account (for HomeKit entitlement)
- HomeKit-configured home with accessories
- Node.js 18+ (for MCP server)
- Xcode 16+ (for building)

## License

MIT
