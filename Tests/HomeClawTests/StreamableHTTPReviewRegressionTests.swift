import XCTest
@preconcurrency import NIOHTTP1
@testable import HomeClaw

private struct ErrorMCPToolRegistry: MCPToolRegistry {
    var toolsJSON: Data { Data("[{\"name\":\"homekit_status\"}]".utf8) }
    func call(name: String, arguments: Data) async -> Data {
        Data("{\"error\":\"tool failed\"}".utf8)
    }
}

private struct HangingMCPToolRegistry: MCPToolRegistry {
    var toolsJSON: Data { Data("[{\"name\":\"homekit_status\"}]".utf8) }
    func call(name: String, arguments: Data) async -> Data {
        try? await Task.sleep(for: .seconds(60)); return Data("{\"status\":\"late\"}".utf8)
    }
}

private struct IgnoringCancellationMCPToolRegistry: MCPToolRegistry {
    var toolsJSON: Data { Data("[{\"name\":\"homekit_status\"}]".utf8) }
    func call(name: String, arguments: Data) async -> Data {
        await Task.detached {
            try? await Task.sleep(for: .seconds(1))
            return Data("{\"status\":\"late\"}".utf8)
        }.value
    }
}

private actor EventLog {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

private actor CallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

final class StreamableHTTPReviewRegressionTests: XCTestCase {
    private let jsonHeaders = ["Content-Type": "application/json", "Accept": "application/json"]
    private let initialize = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}".utf8)

    func testResponseOrderGateReleasesConcurrentRequestsInReservationOrder() async {
        let gate = MCPHTTPResponseOrder()
        let first = gate.reserve()
        let second = gate.reserve()
        let events = EventLog()

        let secondTask = Task {
            await gate.waitTurn(second)
            await events.append("second")
            gate.finish(second)
        }
        try? await Task.sleep(for: .milliseconds(10))
        let eventsBeforeFirst = await events.events
        XCTAssertEqual(eventsBeforeFirst, [])

        let firstTask = Task {
            await gate.waitTurn(first)
            await events.append("first")
            gate.finish(first)
        }
        _ = await firstTask.value
        _ = await secondTask.value
        let finalEvents = await events.events
        XCTAssertEqual(finalEvents, ["first", "second"])
    }

    func testHandlerLifecycleRetiresCompletedTaskAndSession() {
        let lifecycle = MCPHTTPHandlerLifecycle()
        let taskID = UUID()
        lifecycle.begin(taskID: taskID, sessionID: "completed")

        lifecycle.finish(taskID: taskID)

        XCTAssertTrue(lifecycle.activeTaskIDs.isEmpty)
        XCTAssertTrue(lifecycle.activeSessionIDs.isEmpty)
    }

    func testHandlerLifecycleKeepsSSESessionWhenPOSTRequestFinishes() {
        let lifecycle = MCPHTTPHandlerLifecycle()
        let sseTaskID = UUID()
        let postTaskID = UUID()
        lifecycle.begin(taskID: sseTaskID, sessionID: "stream")
        lifecycle.markSSEActive(SSEStreamOwnership(sessionID: "stream", token: UUID()))
        lifecycle.begin(taskID: postTaskID, sessionID: "stream")

        lifecycle.finish(taskID: postTaskID)

        XCTAssertEqual(lifecycle.activeSessionIDs, ["stream"])
        XCTAssertEqual(lifecycle.activeTaskIDs, [sseTaskID])
        XCTAssertTrue(lifecycle.activeSSESessionIDs.contains("stream"))
    }

    func testHandlerLifecycleChannelCloseReturnsAllSSESessions() {
        let lifecycle = MCPHTTPHandlerLifecycle()
        let taskID = UUID()
        lifecycle.begin(taskID: taskID, sessionID: "stream")
        lifecycle.markSSEActive(SSEStreamOwnership(sessionID: "stream", token: UUID()))

        let cleaned = lifecycle.cancelAll()

        XCTAssertEqual(cleaned, ["stream"])
        XCTAssertTrue(lifecycle.activeTaskIDs.isEmpty)
        XCTAssertTrue(lifecycle.activeSessionIDs.isEmpty)
        XCTAssertTrue(lifecycle.activeSSESessionIDs.isEmpty)
    }

    func testCancelledRequestCleansSSEAfterActorRequestReturns() async {
        let log = EventLog()
        await log.append("request-started")
        await log.append("continuation-registered")
        await log.append("request-returned")

        await MCPHTTPHandler.cleanupCancelledRequestIfNeeded(sseOwnership: SSEStreamOwnership(sessionID: "stream", token: UUID()), isCancelled: true) { ownership in
            await log.append("cleanup \(ownership.sessionID)")
        }

        let actualEvents = await log.events
        XCTAssertEqual(actualEvents, ["request-started", "continuation-registered", "request-returned", "cleanup stream"])
    }

    func testCompletedPOSTDoesNotCleanSSE() async {
        let counter = CallCounter()

        await MCPHTTPHandler.cleanupCancelledRequestIfNeeded(sseOwnership: nil, isCancelled: false) { _ in
            await counter.increment()
        }

        let finalCount = await counter.count
        XCTAssertEqual(finalCount, 0)
    }

    func testMCPPathUsesRequestPathNotAbsoluteEndpointURL() async {
        let response = await MCPServer().handleHTTPRequest(HTTPRequest(method: "POST", uri: "/mcp", headers: jsonHeaders, body: initialize))
        XCTAssertEqual(response.statusCode, 200)
    }

    func testProtocolErrorsAreJSONRPCAnd405AdvertisesAllow() async throws {
        let unsupported = await MCPServer().handleHTTPRequest(HTTPRequest(method: "PUT", headers: jsonHeaders))
        XCTAssertEqual(unsupported.statusCode, 405)
        XCTAssertEqual(unsupported.header("Allow"), "GET, POST, DELETE")
        XCTAssertEqual(unsupported.header("Content-Type"), "application/json; charset=utf-8")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(unsupported.bodyData)) as? [String: Any])
        XCTAssertEqual(object["error"] as? [String: Any] != nil, true)
    }

    func testNotificationIsBasedOnMissingIDNotMethodPrefix() async throws {
        let server = MCPServer()
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: jsonHeaders, body: initialize))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let headers = jsonHeaders.merging(["Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.supportedProtocolVersion]) { _, new in new }
        let request = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"notifications/custom\",\"params\":{}}".utf8)
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: request))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.bodyString?.contains("\"id\":2") == true)
        let notification = Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/custom\"}".utf8)
        let notificationResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: notification))
        XCTAssertEqual(notificationResponse.statusCode, 202)
        XCTAssertNil(notificationResponse.bodyData)
    }

    func testNonInitializeRequiresSupportedProtocolVersion() async throws {
        let server = MCPServer()
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: jsonHeaders, body: initialize))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}".utf8)
        let base = jsonHeaders.merging(["Mcp-Session-Id": session]) { _, new in new }
        let baseResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: base, body: body))
        XCTAssertEqual(baseResponse.statusCode, 400)
        let supported = base.merging(["MCP-Protocol-Version": "2025-06-18"]) { _, new in new }
        let supportedResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: supported, body: body))
        XCTAssertEqual(supportedResponse.statusCode, 200)
    }

    func testWildcardAcceptIsAccepted() async {
        let response = await MCPServer().handleHTTPRequest(HTTPRequest(method: "POST", headers: ["Host": "127.0.0.1", "Content-Type": "application/json", "Accept": "*/*"], body: initialize))
        XCTAssertEqual(response.statusCode, 200)
    }

    func testDuplicateHeadersCombineCaseInsensitively() {
        var headers = HTTPHeaders()
        headers.add(name: "Accept", value: "application/json")
        headers.add(name: "accept", value: "text/event-stream")
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "content-type", value: "application/json; charset=utf-8")

        let normalized = MCPHTTPHandler.normalizedHeaders(from: headers)

        XCTAssertEqual(normalized["Accept"], "application/json, text/event-stream")
        XCTAssertEqual(normalized["Content-Type"], "application/json, application/json; charset=utf-8")
    }

    func testNormalDispatchCancelsAndReleasesTimeoutSleeper() async {
        let result = await DispatchTimeoutRace.run(timeout: .seconds(1), timeoutValue: "timeout") {
            for _ in 0..<100 where MCPServer.testActiveTimeoutSleeperCount == 0 {
                await Task.yield()
            }
            return "done"
        }

        XCTAssertEqual(result, "done")
        for _ in 0..<100 where MCPServer.testActiveTimeoutSleeperCount != 0 {
            await Task.yield()
        }
        XCTAssertEqual(MCPServer.testActiveTimeoutSleeperCount, 0)
    }

    func testToolDispatchTimeoutReturnsError() async throws {
        let server = MCPServer(toolRegistry: HangingMCPToolRegistry(), dispatchTimeout: .milliseconds(10))
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: jsonHeaders, body: initialize))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let request = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"homekit_status\"}}".utf8)
        let headers = jsonHeaders.merging(["Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.supportedProtocolVersion]) { _, new in new }
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: request))
        XCTAssertTrue(response.bodyString?.contains("timed out") == true)
    }

    func testToolDispatchTimeoutIsBoundedWhenRegistryIgnoresCancellation() async throws {
        let server = MCPServer(toolRegistry: IgnoringCancellationMCPToolRegistry(), dispatchTimeout: .milliseconds(10))
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: jsonHeaders, body: initialize))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let request = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"homekit_status\"}}".utf8)
        let headers = jsonHeaders.merging(["Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.supportedProtocolVersion]) { _, new in new }
        let clock = ContinuousClock()
        let start = clock.now
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: request))
        let elapsed = start.duration(to: clock.now)
        XCTAssertTrue(response.bodyString?.contains("Tool dispatch timed out") == true)
        XCTAssertLessThan(elapsed, .milliseconds(500))
    }

    func testNativeToolRejectsFractionalAndOutOfRangeIntegers() async throws {
        let fractional = try JSONSerialization.data(withJSONObject: ["limit": 1.5])
        let outOfRange = try JSONSerialization.data(withJSONObject: ["duration_seconds": 86401])
        let fractionalResult = String(decoding: await ToolHandlers.call(name: "homekit_events", arguments: fractional), as: UTF8.self)
        XCTAssertTrue(fractionalResult.contains("Invalid arguments"))
        let outOfRangeResult = String(decoding: await ToolHandlers.call(name: "homekit_events", arguments: outOfRange), as: UTF8.self)
        XCTAssertTrue(outOfRangeResult.contains("Invalid arguments"))
    }
    func testToolsListUsesRegisteredHomeClawTools() async throws {
        let server = MCPServer()
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: jsonHeaders, body: initialize))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let request = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}".utf8)
        let headers = jsonHeaders.merging(["Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.supportedProtocolVersion]) { _, new in new }
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: request))
        XCTAssertTrue(response.bodyString?.contains("homekit_status") == true)
    }

    func testReadOnlyHomeKitToolDispatchesThroughRegistry() async throws {
        let registry = HomeClawMCPToolRegistry.test(status: "registered")
        let server = MCPServer(toolRegistry: registry)
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: jsonHeaders, body: initialize))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let request = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"homekit_status\",\"arguments\":{}}}".utf8)
        let headers = jsonHeaders.merging(["Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.supportedProtocolVersion]) { _, new in new }
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: request))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.bodyString?.contains("registered") == true)
    }

    func testGetReturnsLiveRequestScopedSSEStreamUntilCancelled() async throws {
        let server = MCPServer()
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: jsonHeaders, body: initialize))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let headers = ["Accept": "text/event-stream", "Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.supportedProtocolVersion]
        let response = await server.handleHTTPRequest(HTTPRequest(method: "GET", headers: headers))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNotNil(response.stream)
        var iterator = response.stream!.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(String(data: try XCTUnwrap(first), encoding: .utf8), ": connected\n\n")
        let pending = Task { await iterator.next() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(pending.isCancelled)
        pending.cancel()
    }

    func testReplacementSSEStreamFinishesPreviousContinuation() async throws {
        let server = MCPServer()
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: jsonHeaders, body: initialize))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let headers = ["Accept": "text/event-stream", "Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.supportedProtocolVersion]

        let first = await server.handleHTTPRequest(HTTPRequest(method: "GET", headers: headers))
        var firstIterator = try XCTUnwrap(first.stream).makeAsyncIterator()
        _ = await firstIterator.next()
        let second = await server.handleHTTPRequest(HTTPRequest(method: "GET", headers: headers))
        XCTAssertNotNil(second.stream)

        let replaced = await firstIterator.next()
        XCTAssertNil(replaced)
    }

    func testOldSSECompletionCannotRetireReplacementStream() async throws {
        let server = MCPServer()
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: jsonHeaders, body: initialize))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let headers = ["Accept": "text/event-stream", "Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.supportedProtocolVersion]
        let first = await server.handleHTTPRequest(HTTPRequest(method: "GET", headers: headers))
        let second = await server.handleHTTPRequest(HTTPRequest(method: "GET", headers: headers))
        let firstOwnership = try XCTUnwrap(first.sseOwnership)
        let secondOwnership = try XCTUnwrap(second.sseOwnership)
        XCTAssertNotEqual(firstOwnership, secondOwnership)

        let lifecycle = MCPHTTPHandlerLifecycle()
        let firstTask = UUID()
        let secondTask = UUID()
        lifecycle.begin(taskID: firstTask, sessionID: session)
        lifecycle.markSSEActive(firstOwnership)
        lifecycle.begin(taskID: secondTask, sessionID: session)
        lifecycle.markSSEActive(secondOwnership)

        lifecycle.finishSSE(firstOwnership)
        lifecycle.finish(taskID: firstTask)

        XCTAssertEqual(lifecycle.activeSessionIDs, [session])
        XCTAssertTrue(lifecycle.activeSSESessionIDs.contains(session))
        XCTAssertTrue(lifecycle.activeSSEOwnerships.contains(secondOwnership))

        lifecycle.finishSSE(secondOwnership)
        lifecycle.finish(taskID: secondTask)
        XCTAssertTrue(lifecycle.activeSessionIDs.isEmpty)
    }

    func testExplicitSSECleanupFinishesContinuation() async throws {
        let server = MCPServer()
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: jsonHeaders, body: initialize))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let response = await server.handleHTTPRequest(HTTPRequest(method: "GET", headers: ["Accept": "text/event-stream", "Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.supportedProtocolVersion]))
        var iterator = try XCTUnwrap(response.stream).makeAsyncIterator()
        _ = await iterator.next()

        await server.cleanupSSE(for: session)

        let cleaned = await iterator.next()
        XCTAssertNil(cleaned)
    }

    func testToolHandlerErrorsBecomeMCPToolErrors() async throws {
        let registry = ErrorMCPToolRegistry()
        let server = MCPServer(toolRegistry: registry)
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: jsonHeaders, body: initialize))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let request = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"homekit_status\",\"arguments\":{}}}".utf8)
        let headers = jsonHeaders.merging(["Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.supportedProtocolVersion]) { _, new in new }

        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(response.bodyData)) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertNil(object["error"])
    }

    func testToolCallRejectsReadOnlyNameNotAdvertisedByRegistry() async throws {
        let server = MCPServer(toolRegistry: ErrorMCPToolRegistry())
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: jsonHeaders, body: initialize))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let request = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"homekit_accessories\",\"arguments\":{\"action\":\"list\"}}}".utf8)
        let headers = jsonHeaders.merging(["Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.supportedProtocolVersion]) { _, new in new }

        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(response.bodyData)) as? [String: Any])
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testPeriodicExpiryCleanupFinishesIdleSSEStream() async throws {
        let store = StreamableHTTPSessionStore(ttl: 1)
        let server = MCPServer(configuration: HTTPMCPConfiguration(sessionTTL: 1), sessionStore: store)
        await server.startExpiryCleanup()
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: jsonHeaders, body: initialize))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let response = await server.handleHTTPRequest(HTTPRequest(method: "GET", headers: ["Accept": "text/event-stream", "Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.supportedProtocolVersion]))
        var iterator = try XCTUnwrap(response.stream).makeAsyncIterator()
        _ = await iterator.next()

        try await Task.sleep(for: .milliseconds(1_100))

        let cleaned = await iterator.next()
        XCTAssertNil(cleaned)
        await server.stop()
    }

    func testSessionExpiryFinishesSSEContinuation() async throws {
        let server = MCPServer(sessionStore: StreamableHTTPSessionStore(ttl: 60))
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: jsonHeaders, body: initialize))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let response = await server.handleHTTPRequest(HTTPRequest(method: "GET", headers: ["Accept": "text/event-stream", "Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.supportedProtocolVersion]))
        var iterator = try XCTUnwrap(response.stream).makeAsyncIterator()
        _ = await iterator.next()

        await server.cleanupExpiredSessions(now: Date().addingTimeInterval(61))

        let cleaned = await iterator.next()
        XCTAssertNil(cleaned)
    }
}
