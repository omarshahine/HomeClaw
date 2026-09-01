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

**Note:** The native Streamable HTTP MCP server binds only to loopback at the fixed endpoint `http://127.0.0.1:9090/mcp`, is owned by the Catalyst app lifecycle, and exposes `/healthz` for readiness. It has no shell-launch, install, or token controls. The Node stdio server remains available for Claude Desktop, Claude Code, and OpenClaw compatibility.

## Project Structure

```
Sources/
  homeclaw/              # Unified Catalyst app (Xcode target via XcodeGen)
    App/                 # UIApplicationDelegate entry point, scene delegates
    Bridge/              # BridgeProtocols.swift (Mac2iOS, iOS2Mac)
    MCP/_disabled/       # Preserved HTTP MCP server code (not compiled)
    HomeKit/             # HomeKitManager, SocketServer, CharacteristicMapper,
                         # AccessoryModel, DeviceMap, CharacteristicCache,
                         # HomeEventLogger, WebhookCircuitBreaker
    Views/               # SettingsView, IntegrationsSettingsView
    Shared/              # AppConfig, AppLogger, HomeClawConfig
    Shared/_disabled/    # Preserved KeychainManager (not compiled)
  macOSBridge/           # AppKit bundle (NSStatusItem menu bar)
    MacOSController.swift  # NSStatusItem + NSMenu
    Info.plist           # NSPrincipalClass: MacOSController
  homeclaw-cli/          # CLI tool (SPM executable + Xcode target)
    Commands/            # list, get, set, search, scenes, automations, status, config, device-map
    Commands/_disabled/  # Preserved token command (not compiled)
    SocketClient.swift   # Direct socket communication
Resources/               # Info.plist, entitlements, app icons
scripts/build.sh         # Build & install script (debug/release for local use)
fastlane/Fastfile        # Release pipeline: archive, upload, beta (TestFlight)
mcp-server/              # Node.js stdio MCP server (wraps homeclaw-cli)
openclaw/                # HomeClaw — OpenClaw plugin
  openclaw.plugin.json   # Plugin manifest (configurable binDir)
  src/index.ts           # Plugin entry point
  skills/homekit/        # HomeKit skill definition

App bundle layout (after build):
  Contents/MacOS/HomeClaw                # Catalyst app executable
  Contents/MacOS/homeclaw-cli            # Bundled CLI binary
  Contents/Resources/macOSBridge.bundle  # AppKit menu bar plugin
  Contents/Resources/mcp-server.js       # Node.js stdio MCP server
  Contents/Resources/openclaw/           # Bundled OpenClaw plugin files
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

### Xcode version

The Xcode this project builds with is pinned in `.xcode-version` (currently
**27.0**, i.e. Xcode beta). `scripts/build.sh` and `fastlane` resolve that pin to
an installed `Xcode.app` by its `CFBundleShortVersionString`, so a beta and a
release build can sit side by side in `/Applications` under any name.

Both print the toolchain in use on every run. If the pinned version is not
installed they fail with the list of what is, rather than silently building on a
different Xcode.

Override for a one-off build:

```bash
XCODE_APP=/Applications/Xcode.app scripts/build.sh --debug
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer fastlane archive
```

Either variable may also live in `.env.local`. When bumping the pin, edit
`.xcode-version`; CI picks it up automatically when the runner image has that
Xcode, and warns instead of failing when it does not.

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
| Webhook endpoint | `config.json` → `webhook.webhookEndpoint` | `"/hooks/homeclaw"` |
| Socket path | App Group container or `/tmp/homeclaw.sock` | Auto-detected |

**Mapped webhooks:** HomeClaw uses mapped webhooks (`/hooks/homeclaw`) instead of direct `/hooks/wake` or `/hooks/agent` calls. OpenClaw's `hooks.mappings` config routes events to a dedicated HomeClaw agent. See [openclaw/openclaw#33271](https://github.com/openclaw/openclaw/issues/33271) for the `/hooks/wake` bug that motivated this change.

## MCP Tools

The stdio MCP server (`mcp-server/`) wraps `homeclaw-cli` and exposes tools for home/room/accessory listing, accessory control, scene management, search, home structure management (rename, rooms, zones), and automation management. Tool schemas are defined in `lib/schemas.js` and handlers in `lib/handlers/homekit.js`.

## Automations (Button Programming)

HomeClaw can create HomeKit automations for programmable switches via the CLI, MCP tools, or socket API. Two creation modes:

- **Inline actions** (`--action` / `actions` array): Creates a scene named after the automation. Each action specifies an accessory, property, and value. Note: the Home app uses a private API for hidden automation-only action sets; our action sets are always visible as scenes.
- **Scene reference** (`--scene` / `scene_id`): Links to an existing named scene visible in the Home app.

Implementation: `HomeKitManager.createAutomation()` creates an `HMEventTrigger` watching the button's `input_event` characteristic linked to an `HMActionSet`. The `resolveActions` helper reuses the same accessory/characteristic resolution as `importScene`. Multi-button accessories use `service_index` to target specific buttons (e.g., Aqara AR009 fast mode: Button 1 = index 1, Button 2 = index 2).

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
- **Build** — builds `homeclaw-cli` via SPM, runs `swift test`, builds `mcp-server` (Node.js)
- **Catalyst App** — runs `xcodegen`, selects the `.xcode-version` Xcode when the
  runner has it, and builds the HomeClaw Catalyst target with
  `CODE_SIGNING_ALLOWED=NO`, asserting `** BUILD SUCCEEDED **`
- **Version Consistency** — checks the plugin manifest versions agree

The two macOS jobs (**Build**, **Catalyst App**) run only on pull requests —
macOS minutes bill at 10x Linux, and re-running them on the merge commit's push
to main duplicated what the PR already proved. Pushes to main run only the
Linux **Version Consistency** job.

CI builds the Catalyst app **unsigned only**. The HomeKit entitlement is App
Store-only and cannot be provisioned on a runner, so CI proves the app target
compiles and links, not that it is signable or distributable. A signed build
still has to happen locally (`scripts/build.sh`) or via `fastlane`.

## Clawpatch Code Review

This repo uses [Clawpatch](https://clawpatch.ai) for local automated code review. Keep `.clawpatch/` ignored; it is generated runtime state containing features, findings, reports, runs, and patch attempts.

Standard workflow:

```bash
clawpatch doctor
clawpatch init          # first time only
clawpatch map
clawpatch review --limit 10
clawpatch report --output .clawpatch/reports/summary.md
clawpatch show --finding <id>
clawpatch fix --finding <id>
clawpatch revalidate --finding <id>
```

If this repo needs hand-authored feature coverage, keep those curated definitions in `tools/clawpatch/features/` and sync/copy them into `.clawpatch/features/` before review. Do not commit `.clawpatch/` generated state.


<!-- BEGIN CLAUDE MEMORY IMPORT: -Users-omarshahine-GitHub-HomeClaw -->
## Imported Claude Project Memory

Durable memory promoted from `~/.claude/projects/-Users-omarshahine-GitHub-HomeClaw/memory` during the AGENTS.md migration. Keep this section current when project-specific operating knowledge changes.

### memory/MEMORY.md

# HomeClaw Project Memory

## Onboarding System (added 2026-02-27)

- **Files**: `OnboardingView.swift`, `HomeKitSetupView.swift`, `IntegrationSetupView.swift` in `Sources/homeclaw/Views/`
- **Scene delegate**: `OnboardingSceneDelegate` in `HomeClawApp.swift` (follows same pattern as `SettingsSceneDelegate`)
- **State tracking**: `UserDefaults.standard.bool(forKey: "isOnboardingCompleted")` — matches OnboardingKit convention
- **Auto-open**: In `didFinishLaunchingWithOptions`, checks the key and opens onboarding scene with 0.5s delay if incomplete
- **Multi-step flow**: Welcome → HomeKit Status → Home Selection (if 2+ homes) → Integration Setup → All Set
- **Main view struct**: `OnboardingFlowView` (not `OnboardingView` to avoid conflicts with OnboardingKit internal type)

## SwiftUI-Onboarding (OnboardingKit) Dependency

- **v1.0.0 API is limited**: Module name is `OnboardingKit`, product is `OnboardingKit`
- The `main` branch has a newer API (`WelcomeScreen.apple()`, `Onboarding` module) but v1.0.0 doesn't
- `FeatureInfo` has public init but INTERNAL stored properties — can't read them back
- Currently using the library for future compatibility; custom welcome screen built instead
- To reset onboarding for testing: `defaults delete com.shahine.homeclaw isOnboardingCompleted`

## Key Patterns

- **Scene gating**: `static var onboardingRequested` flag prevents UIKit scene session restoration from showing the window
- **Catalyst ObjC runtime**: `activateIgnoringOtherApps:`, `center`, `orderFrontRegardless` for window management in accessory mode
- **HomeKit observation**: `.homeKitStatusDidChange` notification carries `ready` and `homeNames` in userInfo
- **Integration install methods**: `IntegrationSetupView` replicates the install logic from `IntegrationsSettingsView` (posix_spawn, AppleScript for admin)

## Release Workflow

- After every archive + upload, generate a **TestFlight tester update** (see `memory/testflight-updates.md`)
- Release tag must match the uploaded build number: `v{version}+{build}` (build number derived from `.build-number` file or git rev-list count)
- CLI binary is sandboxed (`com.apple.security.app-sandbox`) — file-based commands can only read from App Group container
- [App Store Connect API setup](asc-api-setup.md) — fastlane `beta` lane drives the full TestFlight release loop
- [Fastlane release pipeline](fastlane-release-pipeline.md) — lanes (archive/upload/beta/status/submit_only/auth_check), Mac Catalyst archive config, env loading from `.env.local` + `~/.secrets.env`

## Feedback: Skill Invocation
- [Use fully qualified skill names for commit](feedback_commit_skill_name.md) — always `commit-commands:commit`, never bare `commit`
- [Greptile MCP plugin fails for HomeClaw](feedback_greptile_mcp.md) — use `gh api` fallback, not MCP tools

## Feedback: External APIs
- [Aqara MCP stdio sticky-session](feedback_aqara_mcp_sticky_session.md) — second switch_home in one stdio session is silently ignored; spawn fresh process per home

## References: External APIs
- [Aqara Open Cloud API intents](reference_aqara_open_api.md) — verified intents for device rename, room rename, room move; use `aqara_call_v3.py` from chief-of-staff plugin
- [Lutron Caseta LEAP write primitives](reference_lutron_leap_primitives.md) — verified UpdateRequest/DeleteRequest/CreateRequest patterns for areas + device-area moves; use `lutron` CLI ≥0.1.8 (subcommands: `area`, `move`)

## Feedback: Build / Distribution
- [SwiftTUI is incompatible with Mac App Store sandbox](feedback_swifttui_sandbox.md) — gate TUI behind `#if !APP_STORE`; sandbox is non-negotiable for MAS bundles

## Cabin / HomeKit
- [Shahine Cabin room ownership](shahine_cabin_rooms.md) — Sarah=Double Bedroom, Miles=Twin Bedroom, "Bedroom Blinds"=Main Bedroom only
- [Trigger-owned (hidden) action sets](private_api_hidden_action_sets.md) — Home app creates per-press button automations as HMActionSets excluded from `home.actionSets`. Read-side: walks `trigger.actionSets`, public API (shipped). Write-side: conclusively gated by Apple-only `com.apple.homekit.private-spi-access` SPI entitlement (investigated + ruled out 2026-05-17). See `docs/PRIVATE_API.md` to skip redoing the dig.

## Fastmail/Chief-of-Staff Architecture (audited 2026-03-07)

**Fastmail is NOT built into chief-of-staff.** Instead:
- **Separate repo**: `fastmail-mcp-remote` (Cloudflare Worker, JMAP adapter, OAuth)
- **HTTP MCP pattern**: Chief-of-staff connects via `FASTMAIL_MCP_URL` env var (Bearer token auth)
- **OpenClaw plugin exists**: `fastmail-cli` (npm v2.1.0) — 36 agent tools, CLI-based, zero deps
- **Permission gating**: 9 categories (EMAIL_READ, INBOX_MANAGE, SEND, REPLY, etc.) controlled server-side
- **Private extensions**: Chief-of-staff-private adds fastmail rules management (browser automation, agent-based)
- **Token efficiency**: CLI formats output as compact text (5-7x savings vs raw JSON)
- **Status**: Mature, production-ready, no new OpenClaw plugin needed

### memory/asc-api-setup.md

---
name: App Store Connect API setup
description: ASC API credentials and fastlane TestFlight pipeline for HomeClaw builds
type: reference
originSessionId: 0b8a6eb4-64d3-4fe3-9fa5-24b075852c4d
---
App Store Connect API is configured for HomeClaw via fastlane.

- **Credentials**: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH` in `~/.secrets.env` (loaded by `fastlane/Fastfile` automatically; `.env.local` for `HOMEKIT_TEAM_ID`)
- **API key file**: `~/.private_keys/AuthKey_<ASC_KEY_ID>.p8`
- **Bundle ID**: `com.shahine.homeclaw`
- **Pipeline**: `fastlane/Fastfile` (archive, upload, beta, status, submit_only, auth_check)
- **External group name**: "External Testers" (resolved dynamically as the first non-internal group)

Full pipeline (archive + upload + TestFlight submit):
```bash
fastlane beta notes_file:/tmp/notes.txt
# or inline notes:
fastlane beta notes:"What to test notes here"
```

Standalone lanes:
```bash
fastlane status                          # latest build status
fastlane status build:143                # specific build
fastlane submit_only build:143 notes_file:/tmp/notes.txt   # recovery: re-submit existing build
fastlane archive                         # archive only, no upload
fastlane upload                          # archive + upload, no external submit
fastlane auth_check                      # validate ASC API key
```

The `/upload` skill auto-generates release notes from git log and runs `fastlane beta` via Monitor.

### memory/fastlane-release-pipeline.md

---
name: Fastlane release pipeline
description: HomeClaw release tooling lives in fastlane/Fastfile (replaced scripts/archive.sh + scripts/asc-testflight.py on 2026-05-08)
type: project
originSessionId: 9b33f14a-8ebf-4226-8eed-b23d580ee1f3
---
HomeClaw's release pipeline runs through fastlane. The legacy `scripts/archive.sh` and `scripts/asc-testflight.py` have been removed.

**Why:** Consolidate archive/export/upload/submit into a single tool that other Shahine iOS apps already use (OnThisDay, bouncer, openclaw/apps/ios), and replace the hand-rolled JWT/HTTP code in `asc-testflight.py` with fastlane's well-maintained pilot/spaceship.

**How to apply:**
- Use `fastlane archive | upload | beta | status | submit_only | auth_check` for all release work
- `fastlane beta` is the full external TestFlight loop (replaces `archive.sh --testflight`)
- Tester notes: `fastlane beta notes_file:/tmp/notes.txt` or `notes:"text"` (also works on `submit_only`)
- The Fastfile's `prepare` private_lane runs `xcodegen generate` + `npm run build:mcp` before every archive
- Mac Catalyst archive uses `catalyst_platform("macos")` + `destination("generic/platform=macOS,variant=Mac Catalyst")` (set in Gymfile)
- Auth: `app_store_connect_api_key` reads `ASC_KEY_ID` + `ASC_ISSUER_ID` + `ASC_KEY_PATH` from `~/.secrets.env`; team ID from `.env.local` (`HOMEKIT_TEAM_ID`)
- Env loader uses `File.binread + .scrub` to survive non-UTF-8 bytes in unrelated values (the bug that broke build 142 with the Python loader)
- External group is resolved dynamically via `Spaceship::ConnectAPI::App.find(BUNDLE_ID).get_beta_groups` (no hardcoded name)
- Build number comes from `.build-number` file (incremented in-memory only, not written back) or `git rev-list --count HEAD` as fallback — same semantics as the old archive.sh
- Marketing version comes from latest `v*` git tag with `+build` suffix stripped (Apple rejects 4-component versions)
- HomeKit entitlement is verified before archive AND on the signed app post-archive (codesign -d --entitlements)

### memory/feedback_aqara_mcp_sticky_session.md

---
name: feedback-aqara-mcp-sticky-session
description: Aqara MCP stdio binary (aqara-mcp-server) silently ignores the second switch_home call in one stdio session — always spawn a fresh process per home
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c361650b-0648-474b-a31d-454a3bb334f5
---

The Aqara MCP stdio binary at `~/.local/bin/aqara-mcp-server run stdio` has a sticky-session bug: the **first** `switch_home` call works correctly, but any **subsequent** `switch_home` in the same stdio session returns `"Successfully switched"` while the next `device_query` continues to return data from the originally selected home.

**Why:** Verified 2026-05-26 during HomeKit cleanup work — same stdio session that switched to "Home" then to "Shahine Cabin" returned identical 30-device main-residence data for both `device_query` calls.

**How to apply:** When querying multiple Aqara homes, spawn one fresh stdio invocation per home (single `initialize → switch_home(target) → device_query` per process). Do **not** batch multiple homes into one heredoc. The fresh-process pattern is what `chief-of-staff/skills/home-ecosystem/scripts/fetch_aqara.py` already does — follow that shape if writing new tooling.

Bonus context: Aqara backend home names + their device contents are independent — renaming a home in the Aqara app does not move devices between homes. If labels and contents disagree, the user must move devices manually OR rename strategically.

Related: [[shahine_cabin_rooms]]

### memory/feedback_commit_skill_name.md

---
name: Use fully qualified skill names for commit
description: Always use commit-commands:commit, never bare commit, when invoking the commit skill
type: feedback
---

Always use `commit-commands:commit` (fully qualified) when invoking the commit skill. The bare name `commit` fails with "Unknown skill: commit".

**Why:** Skills are namespaced under their plugin. Claude Code requires the `plugin:skill` format. The bare name doesn't resolve.

**How to apply:** Any time you need to commit, use `Skill("commit-commands:commit")`. Same pattern for other commit-commands skills: `commit-commands:commit-push-pr`, `commit-commands:clean_gone`, etc.

### memory/feedback_greptile_mcp.md

---
name: Greptile MCP plugin fails for HomeClaw
description: Greptile MCP tool returns "Repository not found" for HomeClaw; use gh api fallback instead
type: feedback
---

The Greptile MCP plugin (`mcp__plugin_greptile_greptile__get_merge_request` etc.) does not work for HomeClaw. It returns "Repository not found: omarshahine/HomeClaw on github". The Greptile GitHub App *does* review PRs successfully (as a check), but the MCP tools can't query it.

**Why:** The repo may not be indexed in Greptile's system, or the MCP token doesn't have access. The GitHub App integration works independently.

**How to apply:** When waiting for Greptile reviews on HomeClaw PRs, skip the MCP plugin entirely. Poll with `gh pr checks` for completion, then fetch comments via `gh api repos/omarshahine/HomeClaw/pulls/{n}/comments` and `gh api repos/omarshahine/HomeClaw/issues/{n}/comments`.

### memory/feedback_swifttui_sandbox.md

---
name: SwiftTUI is incompatible with Mac App Store sandbox
description: PR #55's TUI broke TestFlight uploads — sandbox is non-negotiable for MAS bundles, SwiftTUI's tcsetattr() fails silently under it
type: feedback
originSessionId: f43e9b52-76c8-40d8-ae02-2f798d72578b
---
SwiftTUI calls `tcsetattr(STDIN_FILENO, ...)` to enter raw mode. Under App Sandbox the call returns success but the terminal stays in cooked mode — the TUI renders but arrow keys/Enter leak through as raw `^[[A^[[B` escape sequences.

**Why:** Confirmed empirically on 2026-05-09 while shipping build 157. Build 154 archived fine but ASC rejected it with error 90296 ("App sandbox not enabled" on `homeclaw-cli`). PR #55's claim that "Apple permits unsandboxed bundled CLI helpers — Xcode's git is the canonical example" is wrong for Mac App Store distribution: every bundled executable must have `com.apple.security.app-sandbox=true` or upload fails.

**How to apply:**
- Mac App Store distribution → CLI must have `ENABLE_APP_SANDBOX: YES`. No exceptions.
- TUI features that need raw terminal mode must be gated behind `#if !APP_STORE` (we set `SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) APP_STORE"` on the homeclaw-cli Release config).
- The TUI still works for `swift run homeclaw-cli ui` from source — SPM doesn't apply the sandbox or the APP_STORE flag.
- If you want a sandbox-compatible TUI later, options are: TermKit (ncurses-backed, more mature) or Bubble Tea (Go); SwiftTUI is a no-go.
- Adding the APP_STORE flag is the right pattern for any future code paths that need to differ between Mac App Store builds and source/dev builds.

### memory/private_api_hidden_action_sets.md

---
name: private-api-hidden-action-sets
description: "HomeKit private API for trigger-owned (hidden-from-Home-app) action sets — what we observed when the Home app creates per-press button automations, and how HomeClaw should treat them."
metadata: 
  node_type: memory
  type: project
  originSessionId: 38a6bec3-c4a5-4e9a-867f-e165352610ba
---

# Hidden Action Sets (HMActionSetTypeTriggerOwned)

When the Apple Home app creates a per-press automation on a programmable switch (e.g., "Single Press do X"), it creates an `HMActionSet` of type `HMActionSetTypeTriggerOwned` via a **private** selector on `HMHome` (signature similar to `addActionSetWithName:actionSetType:completionHandler:`). The `TriggerOwned` constant exists in the HomeKit framework but is not declared public.

**Why:** Use the private API in non-App-Store builds (Debug + local Release) so HomeClaw's CLI/MCP can create automations without polluting the user's Scenes list. App Store archives must strip the flag — Apple rejects uploads that reference the selector or constant.

**How to apply:**

## What we proved (2026-05-17, Shahine Cabin, Kitchen Blinds Button)

We snapshotted button B9A5C450-5802-51FA-82AA-5EAE233AB8AD before + after Omar manually rewired its 3 automations through the Home app UI. Diff at `/tmp/homeclaw-private-api-snapshot/{before,after}/summary.json`.

| Aspect | Public API (`home.addActionSet(withName:)`) | Hidden (created by Home app per-button automation) |
|---|---|---|
| Appears in `home.actionSets` | ✅ yes | ❌ no |
| `homeclaw-cli scenes` (pre-fix) | ✅ yes | ❌ silently missing |
| `homeclaw-cli scenes` (post-fix) | ✅ yes, no `hidden` field | ✅ yes, with `"hidden": true` |
| Reachable via `trigger.actionSets` | ✅ yes | ✅ yes |
| `actionSetType` value | `HMActionSetTypeUserDefined` | `HMActionSetTypeUserDefined` (same!) |
| Action set `name` | what you set | opaque UUID string (Home app generated) |
| Visible as scene tile in Home app | ✅ yes (annoying) | ❌ no (goal) |

**Critical correction to original hypothesis**: hidden action sets are NOT `HMActionSetTypeTriggerOwned`. They report `actionSetType == HMActionSetTypeUserDefined` — identical to visible action sets. The hidden behavior comes solely from being attached to a trigger and **excluded from `home.actionSets` enumeration** (Home app filters that list). The "trigger-owned" name is colloquial only.

Implication for the write-side: the trick may not be a different type constant — it may be a private creation path that registers the action set with a trigger atomically AND keeps it out of `home.actionSets`. To verify, we'd need to runtime-inspect the private selector Home app actually uses (likely on `HMHome` taking a trigger reference, e.g. `_addActionSet:toTrigger:` or similar).

## Read-side (always-on, App Store safe)

`home.actionSets` does NOT include trigger-owned sets. To enumerate or inspect them:
- Walk `home.triggers`, then each trigger's `.actionSets` property
- Same `HMActionSet` API — actions, name, uniqueIdentifier all work normally
- The `actionSetType` property returns `HMActionSetTypeTriggerOwned` (public string constant — safe to read)

`homeclaw-cli scenes` and `get-scene` should fall back to scanning `trigger.actionSets` when a scene isn't in `home.actionSets`. Tag results with `"hidden": true` and `"type": "trigger_owned"`.

## Write-side: GATED BY SPI ENTITLEMENT (conclusively investigated 2026-05-17)

The HomeKit daemon (`homed`) checks `com.apple.homekit.private-spi-access` on
the calling app for any mutation to a trigger-owned action set. This entitlement
is Apple-signed-apps-only — not in the `com.apple.developer.homekit` family,
not grantable via Apple Developer Program provisioning.

Confirmed by `codesign -d --entitlements - /System/Applications/Home.app`.

### What works without the SPI

- Read all trigger-owned action sets (walk `home.triggers` → `trigger.actionSets`)
- Create empty trigger-owned action set via private `HMTrigger.addActionSetWithCompletionHandler:` — persists, but is useless because it can't be populated
- Modify a trigger-owned set's local in-memory `actions` array via `_doAddAction:uuid:` — does NOT sync to homed, reverts on app restart

### What does NOT work

- Populate (`addAction:`, `_addAction:`) — fails with "Missing entitlement for API"
- Any persisting mutation of a trigger-owned action set

### Decision: rollback

Write-side code (PrivateActionSets.swift, HOMECLAW_PRIVATE_API flag,
createAutomation private branch) was rolled back. The investigation lives in
`docs/PRIVATE_API.md` so we don't redo it. Open Apple Feedback FB7775451 tracks
the policy if Apple ever opens it up.

## Cleanup note

Two orphaned `user_defined` scenes from the old public-API setup linger in `home.actionSets`: `BD006088-E998-5022-9D0E-AC1FCD9EB571` (Kitchen Blinds Button Single Press) and `9EDAED55-98B1-54E2-B865-2BEF24949DD3` (Kitchen Blinds Button Double Press). Safe to delete — no longer referenced.

## Related

- [[onboarding-system]] — unrelated but tracks similar Catalyst-specific HomeKit quirks
- Code: `Sources/homeclaw/HomeKit/HomeKitManager.swift:1200-1210` (current public-only `addActionSet` call site)
- Code: `Sources/homeclaw/HomeKit/AccessoryModel.swift:679-690` (`actionSetType` helper — already aware of public type constants)

### memory/reference_aqara_open_api.md

---
name: reference-aqara-open-api
description: "Aqara Open Cloud API intents we've verified for HomeKit / Aqara reconciliation work (rename device, move device, rename room, list rooms)"
metadata: 
  node_type: memory
  type: reference
  originSessionId: c361650b-0648-474b-a31d-454a3bb334f5
---

The chief-of-staff plugin's `aqara_call_v3` module (at `~/GitHub/chief-of-staff/plugins/chief-of-staff/skills/home-ecosystem/scripts/aqara_call_v3.py`) wraps the Aqara Open Cloud API. Auth is via `aqara_api_key` + `aqara_base_url` + `aqara_open_*` env vars (loaded from `.secrets-macbook-pro.env`).

## Working intents (verified 2026-05-26)

| Intent | Purpose | Required payload | Notes |
|---|---|---|---|
| `query.device.info` | List all devices in account | `{}` | Returns 41+ devices across all homes (filter by `positionId` for one home) |
| `config.device.name` | Rename a device | `{"did": "<did>", "name": "<new>"}` | Used by `rename_device()` helper |
| `config.device.position` | Move device to another room | `{"dids": ["<did>"], "positionId": "<pos_id>"}` | ⚠ **MUST be `dids` (list)**, not singular `did`. The helper `update_device_position()` had this bug — fixed in PR #25 |
| `query.position.info` | List positions (homes or rooms) | `{"parentPositionId": "<home_pos>", "pageNum": 1, "pageSize": 100}` for rooms; no parent = top-level homes | Position IDs look like `real1.xxx` (home) or `real2.xxx` (room) |
| `config.position.update` | Rename a position (home or room) | `{"positionId": "<pos_id>", "positionName": "<new>"}` | ⚠ `config.position.name` returns 403 — use `config.position.update` |

## Position IDs cached for this account

- Home (top-level): `real1.999309768942440448`
- Shahine Cabin (top-level): `real1.1074271456971436032`

Room IDs vary; query with `query.position.info` + parent home id.

## Aqara MCP stdio binary

`~/.local/bin/aqara-mcp-server run stdio` exposes a subset of these as MCP tools (device_query, device_control, switch_home, etc.) but **no rename / position-update tools**. For renames, call the REST API directly via `aqara_call_v3.call("<intent>", {...})`.

Also note: [[feedback_aqara_mcp_sticky_session]] — the second `switch_home` in one stdio session is silently ignored.

### memory/reference_lutron_leap_primitives.md

---
name: reference-lutron-leap-primitives
description: "LEAP protocol primitives for Lutron Caseta area + device-area writes (rename, delete, create, move) — now exposed via lutron-cli ≥0.1.8"
metadata: 
  node_type: memory
  type: reference
  originSessionId: c361650b-0648-474b-a31d-454a3bb334f5
---

The Lutron Caseta bridge speaks LEAP (a custom JSON-over-TLS protocol). `pylutron_caseta`'s `Smartbridge._request(verb, href, body=None)` is the underlying primitive — most reads/writes route through it. Verified live against an L-BDG2-WH bridge.

## Verified write paths

| Operation | LEAP call | Body |
|---|---|---|
| Rename device | `UpdateRequest /device/<id>` | `{"Device": {"Name": "<new>"}}` |
| Move device to another area | `UpdateRequest /device/<id>` | `{"Device": {"AssociatedArea": {"href": "/area/<id>"}}}` |
| Rename area | `UpdateRequest /area/<id>` | `{"Area": {"Name": "<new>"}}` |
| Delete area | `DeleteRequest /area/<id>` | (none) |
| Create area | `CreateRequest /area` | `{"Area": {"Name": "<n>", "Parent": {"href": "/area/<parent>"}}}` |

After mutating, the bridge auto-recomputes `FullyQualifiedName` ([area_name, device_name]) on affected devices.

## Gotchas

- **Area-existence check is two-step.** Some Caseta firmware versions answer not-found area reads with a 200 + empty body rather than raising. Always check `if response.Body.get("Area") is None: raise`.
- **`config.device.position`-style payload doesn't apply** — that's the Aqara API. For Lutron, use the `AssociatedArea.href` pattern above.
- **Picos don't bridge to HomeKit** — they exist in Lutron but HomeKit sees only WallDimmer/WallSwitch/Shade/Doorbell/etc.
- **The `lutron` CLI ≥ 0.1.8** wraps all of these as proper subcommands: `lutron rename`, `lutron move`, `lutron area rename/delete/create/list`. Prefer those over ad-hoc `bridge._request` scripts.

## Smoke-test pattern (for new bridges or after upgrades)

```python
import asyncio, sys
sys.path.insert(0, '/Users/omarshahine/GitHub/lutron-cli/src')
from lutron_cli.bridge import open_bridge

async def main():
    async with open_bridge("192.168.1.57") as bridge:
        r = await bridge._request("ReadRequest", "/area/1")
        print(r.Body)

asyncio.run(main())
```

### memory/shahine_cabin_rooms.md

---
name: Shahine Cabin room ownership
description: Which HomeKit room belongs to which family member at the cabin
type: project
originSessionId: 7a734e43-23a5-4874-9abf-0f9f7daf1ca0
---
Shahine Cabin HomeKit room mapping (confirmed 2026-04-26):
- **Sarah** = Double Bedroom (has Double Blinds + Transom Blinds + Overhead light)
- **Miles** = Twin Bedroom (has Twin Bedroom North + South Blinds + Overhead light)
- **Owners' suite** = Main Bedroom (Main Bedroom Blinds + Overhead + Closet Light)

**Why:** Several scenes named "Sarah" / "Miles" target their bedrooms. Several button automations are also named "Sarah's Bedroom Button" / "Miles's Bedroom Button" but live in the generically-named rooms.

**How to apply:** When a scene name says Sarah → target Double Bedroom devices. When it says Miles → target Twin Bedroom. "Bedroom Blinds" (without name) refers to **Main Bedroom only** — owners' suite, not all bedrooms.

### memory/testflight-updates.md

# TestFlight Tester Update Template

After every release build + upload, generate a tester update for App Store Connect.

## Where to Post

App Store Connect > Apps > HomeClaw > TestFlight > (select build) > What to Test

## Template Format

```
Build {BUILD_NUMBER} — {SHORT_TITLE}

New in this build:

- **{feature_1}** — {description}
- **{feature_2}** — {description}

What to test:
1. {specific test step}
2. {specific test step}
3. Verify existing commands still work as expected

{any caveats or known issues}
```

## Key Points

- Keep it concise — testers skim
- Lead with what's new, then what to test
- Mention `--dry-run` when available so testers don't accidentally modify their HomeKit setup
- Note sandbox restrictions if file-based commands are involved
- No API access configured — generate text for manual paste into ASC
- ASC API key exists at `~/.appstoreconnect/private_keys/AuthKey_[REDACTED:APP_STORE_CONNECT_API_KEY_ID].p8` but issuer ID is unknown

## Release Workflow Checklist

1. Update README with new features
2. Merge PR to main
3. Create release tag matching build number: `v{version}+{build}`
4. Archive and upload: `fastlane upload` (or `fastlane beta` for full external TestFlight loop)
5. Create GitHub release: `gh release create ...`
6. Generate tester update text for App Store Connect

<!-- END CLAUDE MEMORY IMPORT: -Users-omarshahine-GitHub-HomeClaw -->


<!-- BEGIN CLAUDE MEMORY IMPORT: -Users-omarshahine-GitHub-HomeKitBridge -->
## Imported Claude Project Memory

Durable memory promoted from `~/.claude/projects/-Users-omarshahine-GitHub-HomeKitBridge/memory` during the AGENTS.md migration.

### memory/MEMORY.md

# HomeKit Bridge Memory

## Critical: XcodeGen and Entitlements

**NEVER run `xcodegen` without verifying entitlements afterward.** XcodeGen regenerates `HomeKitHelper.entitlements` from `project.yml`. If the `entitlements.properties` block is missing or wrong, it writes an empty `<dict/>`, silently stripping `com.apple.developer.homekit`. This causes `readValue()` to return nil for all characteristics — accessories are enumerable but all values are nil.

The `project.yml` now has `properties: com.apple.developer.homekit: true` and the build script validates the entitlement before building. But always double-check after running xcodegen.

## Build Commands

- `scripts/build.sh --debug --skip-helper` — fast SPM-only iteration
- `scripts/build.sh --release --install` — full build + install to /Applications
- After adding new files to `Sources/HomeKitHelper/`, must run `cd Sources/HomeKitHelper && xcodegen` then verify entitlements

## Architecture Notes

- `HomeKitManager` is `@MainActor` — long-running operations (like cache warming) need `Task.yield()` between iterations to avoid starving socket request processing
- `HelperSocketServer` bridges GCD → MainActor via semaphore — MainActor starvation causes socket request timeouts and UI freezes

<!-- END CLAUDE MEMORY IMPORT: -Users-omarshahine-GitHub-HomeKitBridge -->
