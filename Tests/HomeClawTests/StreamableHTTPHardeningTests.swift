import XCTest
import Darwin
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
import NIOEmbedded
@testable import HomeClaw

/// A registry whose calls suspend until released, and which records every call.
private actor GateRegistry: MCPToolRegistry {
    nonisolated let toolsJSON: Data
    private(set) var calls: [String] = []
    private var waiters: [CheckedContinuation<Data, Never>] = []
    init(toolsJSON: Data = ToolHandlers.allToolsJSON) { self.toolsJSON = toolsJSON }
    func call(name: String, arguments: Data) async -> Data {
        calls.append(name)
        return await withCheckedContinuation { waiters.append($0) }
    }
    func releaseAll() { waiters.forEach { $0.resume(returning: Data("{}".utf8)) }; waiters.removeAll() }
}

/// Records calls and answers immediately.
private actor ImmediateRegistry: MCPToolRegistry {
    nonisolated let toolsJSON: Data
    private(set) var calls: [(name: String, arguments: [String: Any])] = []
    init(toolsJSON: Data = ToolHandlers.allToolsJSON) { self.toolsJSON = toolsJSON }
    func call(name: String, arguments: Data) async -> Data {
        calls.append((name, (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]))
        return Data(#"{"ok":true}"#.utf8)
    }
    var callNames: [String] { calls.map(\.name) }
}

/// Sends a tools/call and reports only whether it succeeded. File-scope on
/// purpose: Tasks in the tests call this instead of `Self.call`, because the
/// Xcode 26 region-based isolation checker rejects Task closures that capture
/// the XCTestCase subclass's dynamic `Self` (it does not on Xcode 27).
fileprivate func toolCallSucceeds(_ server: MCPServer, headers: [String: String], _ name: String, id: Int = 7) async throws -> Bool {
    let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": [String: String]()]])
    let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: body))
    guard response.statusCode == 200,
          let data = response.bodyData,
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return object["error"] == nil
}

final class StreamableHTTPHardeningTests: XCTestCase {
    private static let jsonHeaders = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"]

    private static func initializeBody(_ version: String) -> Data {
        Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#.utf8)
    }

    private static func object(_ response: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(response.bodyData)) as? [String: Any])
    }

    /// Initializes and returns follow-up headers carrying the negotiated version.
    private static func open(_ server: MCPServer, version: String = "2025-06-18") async throws -> (headers: [String: String], negotiated: String) {
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: Self.jsonHeaders, body: Self.initializeBody(version)))
        XCTAssertEqual(response.statusCode, 200)
        let session = try XCTUnwrap(response.header("Mcp-Session-Id"))
        let result = try XCTUnwrap(try Self.object(response)["result"] as? [String: Any])
        let negotiated = try XCTUnwrap(result["protocolVersion"] as? String)
        return (Self.jsonHeaders.merging(["Mcp-Session-Id": session, "MCP-Protocol-Version": negotiated]) { _, new in new }, negotiated)
    }

    private static func call(_ server: MCPServer, headers: [String: String], _ name: String, _ arguments: [String: Any] = [:], id: Int = 7) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: body))
        XCTAssertEqual(response.statusCode, 200)
        return try Self.object(response)
    }

    /// Polls until the predicate holds (bounded to ~2s).
    private static func eventually(_ predicate: @Sendable () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func rpc(_ server: MCPServer, headers: [String: String], method: String, id: Int = 9) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method])
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: body))
        XCTAssertEqual(response.statusCode, 200)
        return try Self.object(response)
    }

    // MARK: 1. Protocol version negotiation

    func testClientOnLatestSDKVersionNegotiatesIt() async throws {
        // @modelcontextprotocol/sdk 1.27 sends LATEST_PROTOCOL_VERSION = 2025-11-25.
        let server = MCPServer()
        let (headers, negotiated) = try await Self.open(server, version: "2025-11-25")
        XCTAssertEqual(negotiated, "2025-11-25")
        let list = try await Self.rpc(server, headers: headers, method: "tools/list")
        XCTAssertNotNil(list["result"])
    }

    func testSupportedOlderVersionIsEchoed() async throws {
        let (_, negotiated) = try await Self.open(MCPServer(), version: "2025-06-18")
        XCTAssertEqual(negotiated, "2025-06-18")
    }

    func testUnknownVersionIsAnsweredWithServerLatest() async throws {
        for requested in ["2099-01-01", "2024-11-05", "2025-03-26", "not-a-date"] {
            let server = MCPServer()
            let (headers, negotiated) = try await Self.open(server, version: requested)
            XCTAssertEqual(negotiated, MCPServer.latestProtocolVersion, requested)
            // The client continues on the version the server offered.
            let list = try await Self.rpc(server, headers: headers, method: "tools/list")
            XCTAssertNotNil(list["result"], requested)
        }
    }

    func testNonStringProtocolVersionIsRejected() async {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":20250618,"capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#.utf8)
        let server = MCPServer()
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: Self.jsonHeaders, body: body))
        XCTAssertEqual(response.statusCode, 400)
        let count = await server.sessionStore.count
        XCTAssertEqual(count, 0)
    }

    func testMissingVersionHeaderFallsBackToNegotiatedVersion() async throws {
        let server = MCPServer()
        var (headers, _) = try await Self.open(server, version: "2025-11-25")
        headers.removeValue(forKey: "MCP-Protocol-Version")
        let list = try await Self.rpc(server, headers: headers, method: "tools/list")
        XCTAssertNotNil(list["result"])
    }

    func testInvalidOriginIsForbidden() async throws {
        let channel = await NIOAsyncTestingChannel(handler: MCPHTTPHandler(server: MCPServer()))
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 9090)).get()
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp", headers: HTTPHeaders([
            ("Host", "127.0.0.1:9090"), ("Origin", "https://evil.example"),
            ("Content-Type", "application/json"), ("Accept", "application/json")]))
        try await channel.writeInbound(HTTPServerRequestPart.head(head))
        try await channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(bytes: Array(Self.initializeBody("2025-11-25")))))
        try await channel.writeInbound(HTTPServerRequestPart.end(nil))
        let part = try await channel.waitForOutboundWrite(as: HTTPServerResponsePart.self)
        guard case .head(let response) = part else { return XCTFail("Expected response head") }
        XCTAssertEqual(response.status, .forbidden)
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }

    // MARK: 10. ping

    func testPingReturnsEmptyResult() async throws {
        let server = MCPServer()
        let (headers, _) = try await Self.open(server)
        let response = try await Self.rpc(server, headers: headers, method: "ping", id: 42)
        XCTAssertNil(response["error"])
        XCTAssertEqual(response["id"] as? Int, 42)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: 2. Deny-by-default tool policy

    func testMutatingAccessoryActionIsRejectedBeforeDispatch() async throws {
        let registry = ImmediateRegistry()
        let server = MCPServer(homeKitReady: true, toolRegistry: registry)
        let (headers, _) = try await Self.open(server)
        for arguments: [String: Any] in [
            ["action": "control", "accessory_id": "x", "characteristic": "power", "value": "true"],
            ["action": "CONTROL"], ["action": 1], ["action": NSNull()], ["action": "unknown"],
        ] {
            let response = try await Self.call(server, headers: headers, "homekit_accessories", arguments)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602, "\(arguments)")
        }
        // Allowed actions, and the default (no action) still work.
        for arguments: [String: Any] in [[:], ["action": "list"], ["action": "search", "query": "lamp"], ["action": "get", "accessory_id": "x"]] {
            let response = try await Self.call(server, headers: headers, "homekit_accessories", arguments)
            XCTAssertNil(response["error"], "\(arguments)")
        }
        let names = await registry.callNames
        XCTAssertEqual(names, Array(repeating: "homekit_accessories", count: 4))
    }

    func testToolWithoutActionRuleRejectsActionArgument() async throws {
        let registry = ImmediateRegistry()
        let server = MCPServer(homeKitReady: true, toolRegistry: registry)
        let (headers, _) = try await Self.open(server)
        for tool in ["homekit_status", "homekit_rooms", "homekit_device_map", "homekit_events"] {
            let response = try await Self.call(server, headers: headers, tool, ["action": "set"])
            XCTAssertNotNil(response["error"], tool)
        }
        let names = await registry.callNames
        XCTAssertTrue(names.isEmpty)
    }

    func testToolAddedWithoutActionAllowlistFailsClosed() async throws {
        // A future edit lists homekit_scenes as action-less. Its schema declares
        // an action (including `trigger`), so it must be neither advertised nor callable.
        let careless = HTTPToolPolicy(rules: HTTPToolPolicy.readOnly.rules.merging([
            "homekit_scenes": .init(actions: .none, requiresHomeKit: false),
        ]) { _, new in new })
        let registry = ImmediateRegistry()
        let server = MCPServer(homeKitReady: true, toolRegistry: registry, toolPolicy: careless)
        let (headers, _) = try await Self.open(server)
        let list = try await Self.rpc(server, headers: headers, method: "tools/list")
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertFalse(tools.contains { $0["name"] as? String == "homekit_scenes" })
        for arguments: [String: Any] in [[:], ["action": "trigger", "scene_id": "s"], ["action": "list"]] {
            let response = try await Self.call(server, headers: headers, "homekit_scenes", arguments)
            XCTAssertNotNil(response["error"], "\(arguments)")
        }
        let names = await registry.callNames
        XCTAssertTrue(names.isEmpty)
    }

    func testUnlistedToolsAreNeverAdvertisedOrCallable() async throws {
        let registry = ImmediateRegistry()
        let server = MCPServer(homeKitReady: true, toolRegistry: registry)
        let (headers, _) = try await Self.open(server)
        let list = try await Self.rpc(server, headers: headers, method: "tools/list")
        let names = Set(try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]]).compactMap { $0["name"] as? String })
        XCTAssertEqual(names, Set(HTTPToolPolicy.readOnly.rules.keys))
        for tool in ["homekit_scenes", "homekit_manage", "homekit_config", "homekit_webhook", "homekit_automations"] {
            let response = try await Self.call(server, headers: headers, tool, ["action": "list"])
            XCTAssertNotNil(response["error"], tool)
        }
        let calls = await registry.callNames
        XCTAssertTrue(calls.isEmpty)
    }

    func testPolicyUnitRules() {
        let policy = HTTPToolPolicy.readOnly
        XCTAssertTrue(policy.allowsCall(name: "homekit_status", arguments: [:]))
        XCTAssertFalse(policy.allowsCall(name: "homekit_status", arguments: ["action": "list"]))
        XCTAssertTrue(policy.allowsCall(name: "homekit_accessories", arguments: [:]))
        XCTAssertFalse(policy.allowsCall(name: "homekit_accessories", arguments: ["action": "control"]))
        XCTAssertFalse(policy.allowsCall(name: "homekit_scenes", arguments: ["action": "list"]))
        // An allowlisted tool whose schema lost its action enum is dropped.
        let drifted: [[String: Any]] = [["name": "homekit_accessories", "inputSchema": ["type": "object", "properties": [:]]]]
        XCTAssertTrue(policy.advertisedTools(from: drifted).isEmpty)
    }

    // MARK: get_accessory freshness contract (parity with lib/freshness.js)

    private static var freshRead: [String: Any] { ["succeeded": true, "observed_at": "2026-09-21T10:00:00.123Z"] }
    private static func detail(refreshed: Bool, attempted: Int, succeeded: Int, reachable: Bool = true, reads: [[String: Any]]? = nil) -> [String: Any] {
        let characteristics = (reads ?? Array(repeating: freshRead, count: attempted)).map { ["type": "power", "read": $0] }
        return ["name": "Lamp", "reachable": reachable, "refreshed": refreshed, "read_attempted": attempted, "read_succeeded": succeeded,
                "services": [["name": "Lamp", "characteristics": characteristics]]]
    }

    func testFreshAccessoryPassesFullyRefreshedPayload() throws {
        let payload = Self.detail(refreshed: true, attempted: 2, succeeded: 2)
        XCTAssertEqual(try ToolHandlers.freshAccessory(payload, noRefresh: false)["name"] as? String, "Lamp")
    }

    func testPartialRefreshBecomesToolError() {
        let payload = Self.detail(refreshed: false, attempted: 3, succeeded: 1)
        XCTAssertThrowsError(try ToolHandlers.freshAccessory(payload, noRefresh: false)) { error in
            XCTAssertEqual(error.localizedDescription, "HomeClaw freshness contract violation: live refresh failed (1 of 3 characteristic reads succeeded); values may be last-known. Pass no_refresh: true to read last-known values")
        }
    }

    func testUnreachableAccessoryBecomesToolError() {
        let payload = Self.detail(refreshed: false, attempted: 2, succeeded: 0, reachable: false)
        XCTAssertThrowsError(try ToolHandlers.freshAccessory(payload, noRefresh: false)) { error in
            XCTAssertEqual(error.localizedDescription, "HomeClaw freshness contract violation: live refresh failed (accessory is not reachable); values may be last-known. Pass no_refresh: true to read last-known values")
        }
    }

    func testNoRefreshAcceptsOnlyExplicitLastKnownPayload() throws {
        let stale = Self.detail(refreshed: false, attempted: 0, succeeded: 0)
        XCTAssertNoThrow(try ToolHandlers.freshAccessory(stale, noRefresh: true))
        // A no-refresh request answered with fresh-read metadata is a contract violation too.
        XCTAssertThrowsError(try ToolHandlers.freshAccessory(Self.detail(refreshed: true, attempted: 1, succeeded: 1), noRefresh: true))
    }

    func testFreshnessRejectsMalformedAttestation() {
        XCTAssertThrowsError(try ToolHandlers.freshAccessory(["refreshed": true], noRefresh: false))
        let inconsistent = Self.detail(refreshed: true, attempted: 2, succeeded: 2, reads: [Self.freshRead])
        XCTAssertThrowsError(try ToolHandlers.freshAccessory(inconsistent, noRefresh: false))
        let badRead = Self.detail(refreshed: true, attempted: 1, succeeded: 1, reads: [["succeeded": true]])
        XCTAssertThrowsError(try ToolHandlers.freshAccessory(badRead, noRefresh: false))
    }

    // MARK: 5. HomeKit readiness

    func testHomeKitToolsFailFastWhenHomeKitNotReady() async throws {
        let registry = GateRegistry()
        let server = MCPServer(homeKitReady: false, toolRegistry: registry)
        let (headers, _) = try await Self.open(server)
        for tool in ["homekit_accessories", "homekit_rooms", "homekit_device_map"] {
            let response = try await Self.call(server, headers: headers, tool)
            let error = try XCTUnwrap(response["error"] as? [String: Any], tool)
            XCTAssertEqual(error["message"] as? String, "HomeKit not ready")
        }
        let calls = await registry.calls
        XCTAssertTrue(calls.isEmpty, "Nothing may park waiting for HomeKit")

        await server.updateHomeKitReady(true)
        let pending = Task { try await toolCallSucceeds(server, headers: headers, "homekit_rooms") }
        try await Self.eventually { let calls = await registry.calls; return !(calls.isEmpty) }
        let after = await registry.calls
        XCTAssertEqual(after, ["homekit_rooms"])
        await registry.releaseAll()
        _ = try await pending.value
    }

    func testStatusStillAnswersWhileHomeKitNotReady() async throws {
        let registry = ImmediateRegistry()
        let server = MCPServer(homeKitReady: false, toolRegistry: registry)
        let (headers, _) = try await Self.open(server)
        let response = try await Self.call(server, headers: headers, "homekit_status")
        XCTAssertNil(response["error"])
    }

    func testStaleReadinessUpdateIsIgnored() async throws {
        let registry = ImmediateRegistry()
        let server = MCPServer(homeKitReady: false, toolRegistry: registry)
        await server.updateHomeKitReady(true, sequence: 2)
        await server.updateHomeKitReady(false, sequence: 1) // arrived late
        let (headers, _) = try await Self.open(server)
        let response = try await Self.call(server, headers: headers, "homekit_rooms")
        XCTAssertNil(response["error"])
    }

    // MARK: 3. Global tool-dispatch cap

    func testGlobalToolDispatchCap() async throws {
        let registry = GateRegistry()
        let server = MCPServer(configuration: HTTPMCPConfiguration(maxConcurrentToolCalls: 2), homeKitReady: true, toolRegistry: registry)
        let (headers, _) = try await Self.open(server)
        let first = Task { try await toolCallSucceeds(server, headers: headers, "homekit_status", id: 1) }
        let second = Task { try await toolCallSucceeds(server, headers: headers, "homekit_status", id: 2) }
        try await Self.eventually { let calls = await registry.calls; return !(calls.count < 2) }
        let busy = try await Self.call(server, headers: headers, "homekit_status", id: 3)
        XCTAssertEqual((busy["error"] as? [String: Any])?["code"] as? Int, -32003)
        await registry.releaseAll()
        _ = try await first.value; _ = try await second.value
        // Capacity is returned once calls finish.
        let later = Task { try await toolCallSucceeds(server, headers: headers, "homekit_status", id: 4) }
        try await Self.eventually { let calls = await registry.calls; return !(calls.count < 3) }
        await registry.releaseAll()
        let succeeded = try await later.value
        XCTAssertTrue(succeeded)
    }

    // MARK: 9. Cancellation propagates through the dispatch race

    func testDispatchRaceResolvesOnCancellation() async {
        let started = expectation(description: "operation started")
        let task = Task {
            await DispatchTimeoutRace.run(timeout: .seconds(30), timeoutValue: "timeout", cancelledValue: "cancelled") {
                started.fulfill()
                try? await Task.sleep(for: .seconds(30))
                return Task.isCancelled ? "operation-cancelled" : "done"
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let clock = ContinuousClock(); let start = clock.now
        task.cancel()
        let value = await task.value
        XCTAssertEqual(value, "cancelled")
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testDispatchRaceAlreadyCancelledReturnsImmediately() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await DispatchTimeoutRace.run(timeout: .seconds(30), timeoutValue: 0, cancelledValue: -1) { 1 }
        }
        let value = await task.value
        XCTAssertEqual(value, -1)
    }

    // MARK: 3 + 8. Idle close, and drain before shutdown

    func testIdleConnectionIsClosedButBusyOneIsNot() async throws {
        let registry = GateRegistry()
        let server = MCPServer(homeKitReady: true, toolRegistry: registry)
        let idle = await NIOAsyncTestingChannel(handler: MCPHTTPHandler(server: server))
        try await idle.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 9090)).get()
        try await idle.eventLoop.submit { idle.pipeline.fireUserInboundEventTriggered(IdleStateHandler.IdleStateEvent.read) }.get()
        try await idle.closeFuture.get()

        let created = await server.sessionStore.create(protocolVersion: "2025-11-25")
        let session = try XCTUnwrap(created?.id)
        let busy = await NIOAsyncTestingChannel(handler: MCPHTTPHandler(server: server))
        try await busy.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 9090)).get()
        try await sendToolCall(busy, session: session)
        try await Self.eventually { let calls = await registry.calls; return !(calls.isEmpty) }
        try await busy.eventLoop.submit { busy.pipeline.fireUserInboundEventTriggered(IdleStateHandler.IdleStateEvent.read) }.get()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(busy.isActive, "A connection with an in-flight request must not be idled out")
        await registry.releaseAll()
        _ = try await busy.finish(acceptAlreadyClosed: true)
    }

    func testStalledPartialRequestIsClosedOnIdle() async throws {
        let server = MCPServer(homeKitReady: true, toolRegistry: GateRegistry())
        let stalled = await NIOAsyncTestingChannel(handler: MCPHTTPHandler(server: server))
        try await stalled.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 9090)).get()
        // Headers promising a body, a fragment of it, then nothing.
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp", headers: HTTPHeaders([
            ("Host", "127.0.0.1"), ("Content-Type", "application/json"), ("Accept", "application/json"), ("Content-Length", "500")]))
        try await stalled.writeInbound(HTTPServerRequestPart.head(head))
        try await stalled.writeInbound(HTTPServerRequestPart.body(ByteBuffer(string: #"{"jsonrpc":"2.0","#)))
        try await stalled.eventLoop.submit { stalled.pipeline.fireUserInboundEventTriggered(IdleStateHandler.IdleStateEvent.read) }.get()
        try await stalled.closeFuture.get()
        XCTAssertFalse(stalled.isActive, "A stalled partial request must not pin the connection")
    }

    func testTrackerShutdownClosesConnectionsAndDrainsInflightTasks() async throws {
        let registry = GateRegistry()
        let server = MCPServer(homeKitReady: true, toolRegistry: registry)
        let tracker = MCPHTTPConnectionTracker(maxConnections: 4)
        let channel = await NIOAsyncTestingChannel(handler: MCPHTTPHandler(server: server, tracker: tracker))
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 9090)).get()
        XCTAssertTrue(tracker.admit(channel))
        let created = await server.sessionStore.create(protocolVersion: "2025-11-25")
        try await sendToolCall(channel, session: try XCTUnwrap(created?.id))
        try await Self.eventually { let calls = await registry.calls; return !(calls.isEmpty) }
        XCTAssertEqual(tracker.taskCount, 1)

        // The tool never returns on its own; shutdown must still drain promptly.
        let clock = ContinuousClock(); let start = clock.now
        await tracker.shutdown()
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
        XCTAssertEqual(tracker.taskCount, 0, "Every request task must finish before the loop shuts down")
        XCTAssertFalse(channel.isActive)
        XCTAssertFalse(tracker.admit(channel), "No new connections after shutdown")
        await registry.releaseAll()
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }

    func testTrackerEnforcesConnectionCap() async throws {
        let tracker = MCPHTTPConnectionTracker(maxConnections: 2)
        let a = EmbeddedChannel(), b = EmbeddedChannel(), c = EmbeddedChannel()
        XCTAssertTrue(tracker.admit(a)); XCTAssertTrue(tracker.admit(b)); XCTAssertFalse(tracker.admit(c))
        XCTAssertEqual(tracker.connectionCount, 2)
        _ = try a.finish(acceptAlreadyClosed: true)
        XCTAssertEqual(tracker.connectionCount, 1, "A closed connection frees its slot")
        XCTAssertTrue(tracker.admit(c))
        _ = try? b.finish(acceptAlreadyClosed: true); _ = try? c.finish(acceptAlreadyClosed: true)
    }

    // MARK: Real listener: connection cap, idle timeout, stop with work in flight

    func testListenerCapsConnectionsIdlesThemOutAndStopsWithWorkInFlight() async throws {
        let registry = GateRegistry()
        var server: MCPServer!
        var port = 0
        for _ in 0..<10 {
            port = Int.random(in: 20000...45000)
            let candidate = MCPServer(configuration: HTTPMCPConfiguration(port: port, maxConnections: 2, idleTimeout: .milliseconds(300)), homeKitReady: true, toolRegistry: registry)
            do { try await candidate.start(); server = candidate; break } catch { continue }
        }
        let listener = try XCTUnwrap(server, "Could not bind a test port")

        // Over the cap: the third connection is closed by the server.
        let first = try RawSocket(port: port), second = try RawSocket(port: port)
        try await Task.sleep(for: .milliseconds(100))
        let third = try RawSocket(port: port)
        // 200ms is shorter than the 300ms idle timeout, so only the cap can close it.
        XCTAssertTrue(third.waitForPeerClose(timeout: 0.2), "Connection beyond the cap must be refused")

        // Idle: with nothing in flight both admitted connections time out.
        XCTAssertTrue(first.waitForPeerClose(timeout: 3), "Idle connection must be closed")
        XCTAssertTrue(second.waitForPeerClose(timeout: 3), "Idle connection must be closed")

        // Stalled partial request (headers plus part of a body): idled out too,
        // so such sockets cannot pin the connection cap.
        let slow = try RawSocket(port: port)
        slow.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nAccept: application/json\r\nContent-Length: 500\r\n\r\n{\"jsonrpc\":")
        XCTAssertTrue(slow.waitForPeerClose(timeout: 3), "Stalled partial request must be idled out")

        // Stop while a tool call is parked: must return promptly (drain, then shut down).
        let created = await listener.sessionStore.create(protocolVersion: "2025-11-25")
        let session = try XCTUnwrap(created?.id)
        let busy = try RawSocket(port: port)
        let body = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"homekit_status","arguments":{}}}"#
        busy.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nAccept: application/json\r\nMcp-Session-Id: \(session)\r\nMCP-Protocol-Version: 2025-11-25\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        try await Self.eventually { let calls = await registry.calls; return !(calls.isEmpty) }
        let calls = await registry.calls
        XCTAssertEqual(calls, ["homekit_status"])
        let clock = ContinuousClock(); let start = clock.now
        await listener.stop()
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(3))
        XCTAssertTrue(busy.waitForPeerClose(timeout: 2))
        await registry.releaseAll()
    }

    private func sendToolCall(_ channel: NIOAsyncTestingChannel, session: String) async throws {
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp", headers: HTTPHeaders([
            ("Host", "127.0.0.1"), ("Content-Type", "application/json"), ("Accept", "application/json"),
            ("Mcp-Session-Id", session), ("MCP-Protocol-Version", "2025-11-25")]))
        try await channel.writeInbound(HTTPServerRequestPart.head(head))
        try await channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(string: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"homekit_status","arguments":{}}}"#)))
        try await channel.writeInbound(HTTPServerRequestPart.end(nil))
    }
}

/// A minimal blocking loopback TCP client for listener-level tests.
private final class RawSocket {
    private let fd: Int32
    init(port: Int) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
    }
    deinit { close(fd) }

    func send(_ text: String) {
        _ = text.utf8CString.withUnsafeBufferPointer { Darwin.send(fd, $0.baseAddress, $0.count - 1, 0) }
    }

    /// Reads (discarding any response bytes) until the peer closes or the timeout passes.
    func waitForPeerClose(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var tv = timeval(tv_sec: 0, tv_usec: 100_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let n = recv(fd, &buffer, buffer.count, 0)
            if n == 0 { return true }
            if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { return true }
        }
        return false
    }
}
