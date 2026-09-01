# Native Streamable HTTP and Hermes Integration

## Status

Proposed design, approved in chat for specification and review.

## Goal

Add a native MCP Streamable HTTP server to the HomeClaw Mac Catalyst app and make it usable from the local Hermes installation without the HomeClaw-specific `supergateway` process. Existing stdio MCP clients and HomeKit tool semantics must remain compatible.

## Scope

### HomeClaw

- Compile and run the existing Swift/NIO HTTP MCP implementation, currently preserved under `Sources/homeclaw/MCP/_disabled/`, after adapting it to the current MCP SDK and application lifecycle.
- Add a loopback-only HTTP listener with a fixed default port of `9090` and a configurable override for tests/developers.
- Expose:
  - `GET /healthz` for a non-MCP liveness/readiness response.
  - `POST /mcp` for Streamable HTTP JSON-RPC messages.
  - `GET /mcp` for a session's SSE stream.
  - `DELETE /mcp` for session termination.
- Implement stateful MCP sessions with `Mcp-Session-Id` returned by initialization and required for subsequent session requests.
- Support JSON responses and request-scoped SSE responses, notification responses with HTTP `202 Accepted` and no body, and protocol-appropriate errors for malformed requests, invalid sessions, unsupported methods, and unacceptable media types.
- Enforce loopback binding and validate `Host`/`Origin` values against loopback forms to prevent DNS-rebinding access.
- Route HTTP requests through the same MCP/HomeKit execution and tool definitions used by the existing implementation; do not add HTTP-only HomeKit operations.
- Preserve the current Node.js stdio server and existing Claude Desktop, Claude Code, and OpenClaw integrations.

### Hermes integration

- Add a HomeClaw section to the existing Integrations settings UI showing the native endpoint, server status, and safe connection-test status.
- Provide a copyable Hermes MCP configuration snippet for `http://127.0.0.1:9090/mcp` and document the running-app prerequisite.
- Make the UI test read-only: health check, MCP initialize, `tools/list`, and `homekit_status`; never perform a mutating HomeKit operation.
- Update the local Hermes configuration through Hermes-supported configuration tooling, replacing the HomeClaw `supergateway` entry with native HTTP MCP configuration.
- Verify the resulting configuration by reading it back and verify the live tool set and `homekit_status` response through Hermes.

## Non-goals

- Remote/non-loopback HomeClaw access or bearer-token authentication.
- Removing or changing stdio support.
- Rewriting the Node.js MCP server.
- Adding new HomeKit operations, changing tool schemas, or changing mutation authorization semantics.
- Automatic app installation, privileged symlinks, secret creation, or HomeKit permission changes.
- Dynamic/ephemeral port discovery.

## Architecture

```text
Hermes native HTTP MCP client
        │
        ▼
127.0.0.1:9090/mcp  ── Swift/NIO Streamable HTTP transport
        │
        ▼
shared MCP server/tool definitions and session execution
        │
        ▼
@MainActor HomeKitManager ── /tmp/homeclaw.sock and HomeKit

Existing stdio clients ── Node.js stdio MCP wrapper ── same CLI/socket/tool semantics
```

The HTTP transport owns HTTP framing, content negotiation, session state, SSE stream lifecycle, and request cancellation. Tool registration and HomeKit dispatch remain in the existing application layer. Session state is isolated per MCP session and must not leak across clients. The listener starts and stops with the HomeClaw app and must report readiness only after its bind succeeds.

The default listener binds to loopback only. A configuration/test override may change the port but must not permit a non-loopback bind in this scope. `Host` and `Origin` checks accept valid loopback host forms and reject public or ambiguous origins. Request bodies, credentials, authenticated URLs, and HomeKit response payloads must not be logged by the transport.

## MCP behavior

- Initialization is accepted without a session ID and creates a session.
- The initialization response includes `Mcp-Session-Id`.
- Requests after initialization require the matching session ID.
- Each POST contains one JSON-RPC request, notification, or response.
- A request may return `application/json` or `text/event-stream` according to the client's `Accept` header and server response choice.
- Notifications and accepted JSON-RPC responses return `202` with an empty body when no response body is required.
- GET requires a valid session and may open the session SSE stream.
- DELETE requires a valid session and releases all session resources.
- Malformed JSON-RPC, invalid session IDs, unsupported HTTP methods, invalid content types, and unacceptable `Accept` headers receive deterministic errors without invoking HomeKit.
- Closing an HTTP response stream cancels the associated in-flight MCP operation.

The implementation must follow the MCP Streamable HTTP specification version supported by the repository's pinned Swift MCP SDK. Compatibility behavior and any SDK limitations must be documented in code comments and tests rather than silently assumed.

## Hermes UI and configuration

The existing integrations UI gains a HomeClaw/Hermes section rather than a second client implementation. It reports three safe states: native endpoint available, HomeClaw not running/not ready, and configuration/test failure. The generated snippet contains only the endpoint and non-secret MCP client settings.

The local Hermes setup is changed using Hermes configuration commands or APIs, not by hand-editing `~/.hermes/config.yaml`. The HomeClaw-specific `supergateway` process is removed from the active path only after the native endpoint is live and the configuration read-back confirms the replacement. Existing unrelated MCP entries remain unchanged.

## Testing and acceptance

### Unit and integration tests

- Listener defaults to port `9090`, permits only loopback binding, and supports test port substitution.
- `/healthz` distinguishes listener liveness from HomeKit readiness without exposing secrets.
- Host and Origin validation accepts loopback forms and rejects non-loopback/rebinding cases.
- Initialization creates a session and returns a session ID; subsequent requests require it.
- Session isolation, GET SSE lifecycle, DELETE cleanup, cancellation, and invalid-session errors are covered.
- JSON response, SSE response, notification `202`, malformed request, method, content-type, and `Accept` handling are covered.
- HTTP and stdio expose equivalent HomeClaw tool names/schemas for the supported MCP surface.
- A representative read-only status operation has equivalent transport behavior without adding a write path.
- Hermes snippet generation, endpoint/port substitution, missing-app state, and read-only test behavior are covered.
- No test requires live credentials; live validation is a separate local acceptance step.

### Local acceptance

1. Build and install HomeClaw with the existing repository build workflow.
2. Start HomeClaw and confirm the native listener binds on loopback port `9090`.
3. Exercise `/healthz`, MCP initialize, `tools/list`, and `homekit_status` directly.
4. Replace the local Hermes HomeClaw wrapper configuration with the native URL using Hermes tooling.
5. Read back the Hermes configuration and invoke `homekit_status` through Hermes.
6. Confirm the expected HomeClaw tool set and inspect logs for absence of secrets/request bodies.
7. Preserve and verify unrelated Hermes MCP entries.

### Repository gates

Run the HomeClaw repository's relevant Node, Swift, and Xcode build/test workflows, including `npm run build:mcp`, `swift test`, and the documented app build/compile checks. Before opening a PR, inspect the final diff, branch, commit, and all available CI conclusions.

## Delivery

Develop on a feature branch from current HomeClaw `main`. Keep HomeClaw source/tests/docs in the upstream branch. Hermes local configuration changes are local environment state and must not be committed to HomeClaw. After local tests and live acceptance pass, push the feature branch to Keith's fork if available and open one PR against `omarshahine/HomeClaw:main`, with explicit test results and any SDK/version caveats. Do not merge automatically.
