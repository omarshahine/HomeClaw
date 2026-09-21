# Archived HTTP MCP prototype — not compiled

This directory preserves the superseded MCP SDK-based prototype for historical
reference. XcodeGen excludes `**/_disabled/**` from the app target. These files
are **not** the active HTTP server; do not move them into the parent directory or
restore their SDK/token dependencies.

## Active implementation

The compiled implementation is in `Sources/homeclaw/MCP/` (the parent directory).
It uses SwiftNIO directly, not `mcp-swift-sdk`. Enable **Streamable HTTP MCP** in
**Settings → Integrations**; the setting is persistent and **off by default**.
When enabled, the Catalyst app serves `http://127.0.0.1:9090/mcp` and `/healthz`.
Turning it off stops the listener. Existing Node stdio and Unix-socket clients
remain supported independently of this setting.

The active security model is loopback-only binding, fail-closed Host/Origin
validation, and a deny-by-default read-only HTTP tool allowlist. It intentionally
has **no bearer token**. The prototype's bearer-token/Keychain design is
superseded, not a missing feature to restore. HomeKit access remains subject to
the app's entitlement and system permission.

## Historical files

| File | Historical purpose |
|------|--------------------|
| `MCPServer.swift` | SDK-based HTTP server actor |
| `MCPHTTPHandler.swift` | HTTP-to-MCP SDK bridge |
| `BearerTokenValidator.swift` | Superseded bearer-token validation |
| `ToolHandlers.swift` | Prototype tool definitions and dispatch |

Related archived code lives in `Sources/homeclaw/Shared/_disabled/`
(`KeychainManager.swift`) and `Sources/homeclaw-cli/Commands/_disabled/`
(`TokenCommand.swift`). Those files also remain excluded from compilation.

For current client setup, see the root README's **Native MCP for Hermes** section.
