# Disabled: HTTP MCP Server

This directory contains the HTTP MCP server implementation that has been disabled.
These files are preserved for reference but are **not compiled** into the app.

## What was here

The app previously ran an HTTP MCP server (NIO-based, port 9090) with bearer token
authentication. All MCP clients now use either:

- **stdio MCP server** (Node.js, `mcp-server/`) — used by Claude Code and Claude Desktop
- **homekit-cli** (SPM binary) — used by OpenClaw

The HTTP server, bearer token auth, and Keychain token management added complexity
without being in the active path for any current client.

## Files

| File | Purpose |
|------|---------|
| `MCPServer.swift` | NIO-based HTTP server actor with session management |
| `MCPHTTPHandler.swift` | NIO ChannelHandler bridging HTTP to MCP SDK |
| `BearerTokenValidator.swift` | Bearer token extraction and validation |
| `ToolHandlers.swift` | MCP tool definitions and dispatch to HomeKitClient |

Related files in `Shared/_disabled/`:

| File | Purpose |
|------|---------|
| `KeychainManager.swift` | macOS Keychain CRUD for bearer tokens |

Related files in `homekit-cli/Commands/_disabled/`:

| File | Purpose |
|------|---------|
| `TokenCommand.swift` | CLI command for viewing/rotating bearer tokens |

## Re-enabling

To re-enable the HTTP server:

1. Move files back from `_disabled/` to their parent directories
2. Restore the MCP SDK dependency in `Package.swift`:
   ```swift
   .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
   ```
3. Add the MCP product dependency to the `homekit-mcp` target
4. Restore `MCPServer` startup in `AppDelegate.swift`
5. Restore `KeychainManager` and token initialization
6. Restore `AppConfig` HTTP constants (port, endpoint, keychain keys)
7. Restore the Server settings tab and menu bar token/port display
8. Add `Token.self` back to `HomeKitCLI` subcommands
