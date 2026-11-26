# Xcode workflow for HomeClaw

Use stable Xcode at `/Applications/Xcode.app/Contents/Developer`. XcodeBuildMCP is pinned to 2.7.0; upgrade it deliberately, separately from a release.

The shared helper is maintained in [Omar’s dotfiles](https://github.com/omarshahine/dotfiles/blob/main/dot_local/bin/executable_setup-xcode-mcp), with [setup documentation](https://github.com/omarshahine/dotfiles/blob/main/docs/xcode-mcp.md). On a Mac already managed by that chezmoi setup, install just the helper and add its directory to this shell’s path:

```sh
chezmoi apply "$HOME/.local/bin/setup-xcode-mcp"
export PATH="$HOME/.local/bin:$PATH"
command -v setup-xcode-mcp
```

The dotfiles repository is private. Contributors without access can perform the same native readiness and workspace-opening steps directly with stable Xcode:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun mcp-server status
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun mcp-server open PROJECT
```

Replace `PROJECT` with the project path below. Inspect enablement, agent approval, and folder coverage before opening; report missing access rather than bypassing it. These commands do not replace any required agent approval.

After changing MCP configuration, restart the agent/client so its tool catalog refreshes. From the active managed worktree, run `setup-xcode-mcp --check` before Apple-platform work. Use `setup-xcode-mcp --open "./HomeClaw.xcodeproj"` to open that project through the supported native Xcode MCP command when the native server needs a workspace. Do not use a GUI for build or release operations.

The default project is `HomeClaw.xcodeproj`, scheme `HomeClaw`, configuration Debug. Select the Mac Catalyst destination for the app. There is no iPhone app destination or default simulator.

Use native Xcode MCP for supported project, build, test, preview, and runtime operations. Use XcodeBuildMCP for supported native macOS CLI/bridge and Swift Package operations when the native server lacks the required capability. Its 2.7.0 macOS tool does not expose a Catalyst variant selector. At the first XcodeBuildMCP action, call `session_show_defaults`. If the project, scheme or destination is missing or stale, call `session_set_defaults` with the active worktree’s resolved physical project path, scheme and destination, and `persist: false`, before invoking an action. Do not reuse another checkout’s paths or settings. For a run, use the combined build-and-run operation.

Use Codex native controls for app and simulator UI interaction. The project configuration does not add the `ui-automation` or `xcode-ide` proxy workflow. Do not start a second native bridge or Device Hub instance.

If native MCP access is unavailable, report its exact readiness or capability failure. For native macOS CLI/bridge or Swift Package operations, the pinned XcodeBuildMCP CLI is a fallback with the same `DEVELOPER_DIR` and worktree. For Catalyst app builds, use the existing repo script described below; the XcodeBuildMCP CLI shares the same missing variant selector as its MCP backend. Do not silently alternate between tools or switch to beta Xcode. Full app builds are not required to validate configuration-only changes.

CLI fallback example, run from the active worktree root only after reporting the native MCP failure or missing capability:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer npx -y xcodebuildmcp@2.7.0 macos build-and-run \
  --project-path "$PWD/HomeClaw.xcodeproj" --scheme HomeClaw --configuration Debug
```

The `macos` workflow selects the Mac destination; `--simulator-name` selects the shared iOS destination. Use the matching workflow for this project. Inspect additional pinned commands with `npx -y xcodebuildmcp@2.7.0 macos --help`; command-specific `--help` shows the supported flags. These examples are development operations, not release commands.

Direct `xcodebuild` is a final development fallback only when the pinned XcodeBuildMCP route is also unavailable or lacks the required operation. State that failure or missing capability before using it, and keep the same stable toolchain, project, scheme, and destination. Existing direct build/test examples in `AGENTS.md` have this same restriction.

Production release routing is described below. Development configuration changes do not authorize an upload or submission. Preserve the repo’s clean-source, signed-artifact, tag, review, entitlement, and beta-toolchain guards. Never use a GUI for build or release operations.

For App Store and TestFlight releases, use `scripts/release.sh` and ASC. Build only clean, committed, pushed, reviewed, and version-tagged source. For an authorized App Store submission, set `AFTER_APPROVAL`, read it back, and record the source SHA, version, and build. Missing or blocked CLI access is a blocker; do not switch to a GUI.

The app is Mac Catalyst only. Keep the existing simulator and macOS workflow visibility and the Swift Package workflow for its native CLI. Select the Mac Catalyst destination through native Xcode MCP. XcodeBuildMCP 2.7.0 does not expose a Catalyst-variant parameter; if the necessary destination cannot be selected there, report that specific capability gap and run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/build.sh --debug` with the existing `HOMEKIT_TEAM_ID` environment. That script selects `platform=macOS,variant=Mac Catalyst`; `--debug` builds without installing, archiving, or uploading. If its required team configuration is unavailable, report the blocker. Do not add an iPhone destination or duplicate `-destination` arguments. The ignored Xcode project is generated from `project.yml`; generate it through the repo’s documented XcodeGen hook when project access is needed.

Keep root `.mcp.json` local and ignored. The Claude plugin distributes the repository root, so tracking developer servers there would register them for HomeKit users. Codex uses `.codex/config.toml`; Claude developers can add a local server with `claude mcp add XcodeBuildMCP --scope local --transport stdio --env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer -- npx -y xcodebuildmcp@2.7.0 mcp`. This preserves the plugin’s existing `homekit` server.
