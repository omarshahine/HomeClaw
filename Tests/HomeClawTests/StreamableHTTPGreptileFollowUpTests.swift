import XCTest
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
import NIOEmbedded
@testable import HomeClaw

/// Calls suspend until released (ignoring cancellation), and are counted.
private actor ParkingRegistry: MCPToolRegistry {
    nonisolated let toolsJSON: Data
    private(set) var calls = 0
    private var waiters: [CheckedContinuation<Data, Never>] = []
    init(toolsJSON: Data = ToolHandlers.allToolsJSON) { self.toolsJSON = toolsJSON }
    func call(name: String, arguments: Data) async -> Data {
        calls += 1
        return await withCheckedContinuation { waiters.append($0) }
    }
    func releaseAll() { waiters.forEach { $0.resume(returning: Data("{}".utf8)) }; waiters.removeAll() }
}

final class StreamableHTTPGreptileFollowUpTests: XCTestCase {
    private static let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#

    private static func open(_ server: MCPServer) async throws -> [String: String] {
        let headers = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"]
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: Data(initialize.utf8)))
        let session = try XCTUnwrap(response.header("Mcp-Session-Id"))
        return headers.merging(["Mcp-Session-Id": session, "MCP-Protocol-Version": "2025-11-25"]) { _, new in new }
    }

    private static func call(_ server: MCPServer, _ headers: [String: String], id: Int) async throws -> [String: Any] {
        let body = Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"homekit_status","arguments":{}}}"#.utf8)
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: body))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(response.bodyData)) as? [String: Any])
    }

    private static func eventually(_ predicate: @Sendable () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Dispatch slots follow the operation, not the request (4059799130)

    func testTimedOutWorkKeepsItsSlotUntilItActuallyEnds() async throws {
        let registry = ParkingRegistry()
        let server = MCPServer(configuration: HTTPMCPConfiguration(maxConcurrentToolCalls: 1), homeKitReady: true, toolRegistry: registry, dispatchTimeout: .milliseconds(20))
        let headers = try await Self.open(server)

        let first = try await Self.call(server, headers, id: 1)
        let text = (((first["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("timed out"), "The response is bounded by the timeout")

        // The operation is still running, so it still holds the only slot.
        let busy = try await Self.call(server, headers, id: 2)
        XCTAssertEqual((busy["error"] as? [String: Any])?["code"] as? Int, -32003)
        let calls = await registry.calls
        XCTAssertEqual(calls, 1, "Abandoned work must not let more work pile up")

        await registry.releaseAll()
        var freed = false
        for _ in 0..<200 {
            let next = try await Self.call(server, headers, id: 3)
            if (next["error"] as? [String: Any])?["code"] as? Int != -32003 { freed = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(freed, "The slot is returned once the operation really finishes")
        await registry.releaseAll()
    }

    func testAdmissionSlotReleasesOnDeinit() {
        let admission = ToolDispatchAdmission(limit: 1)
        var slot = admission.acquire()
        XCTAssertNotNil(slot)
        XCTAssertNil(admission.acquire())
        slot = nil
        _ = slot
        XCTAssertEqual(admission.activeCount, 0)
        XCTAssertNotNil(admission.acquire())
    }

    @MainActor
    func testWaitForReadyReturnsWhenCallerIsCancelled() async throws {
        // Unit tests never start HomeKit, so this wait would otherwise park forever.
        XCTAssertFalse(HomeKitManager.shared.isReady)
        let waiter = Task { @MainActor in await HomeKitManager.shared.waitForReady() }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        let finished = expectation(description: "waitForReady returned")
        Task { await waiter.value; finished.fulfill() }
        await fulfillment(of: [finished], timeout: 2)
    }

    // MARK: GET/DELETE registration race (4059799137)

    func testConcurrentDeleteNeverLeavesAStreamForADeletedSession() async throws {
        let server = MCPServer()
        for _ in 0..<150 {
            let headers = try await Self.open(server)
            let session = try XCTUnwrap(headers["Mcp-Session-Id"])
            var sse = headers; sse["Accept"] = "text/event-stream"
            let get = Task { await server.handleHTTPRequest(HTTPRequest(method: "GET", headers: sse)).statusCode }
            let delete = Task { await server.handleHTTPRequest(HTTPRequest(method: "DELETE", headers: headers)).statusCode }
            _ = await get.value; _ = await delete.value
            let owned = await server.testSSEOwnerships.contains { $0.sessionID == session }
            let stored = await server.sessionStore.get(session); let exists = stored != nil
            XCTAssertFalse(owned && !exists, "A stream outlived its deleted session")
        }
    }

    // MARK: Configured per-channel limit is honored (4059799141)

    func testConfiguredPerChannelInflightLimitIsUsed() async throws {
        let registry = ParkingRegistry()
        let server = MCPServer(homeKitReady: true, toolRegistry: registry)
        let opened = try await Self.open(server)
        let session = try XCTUnwrap(opened["Mcp-Session-Id"])
        let channel = await NIOAsyncTestingChannel(handler: MCPHTTPHandler(server: server, maxInflight: 1))
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 9090)).get()
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp", headers: HTTPHeaders([
            ("Host", "127.0.0.1"), ("Content-Type", "application/json"), ("Accept", "application/json"),
            ("Mcp-Session-Id", session), ("MCP-Protocol-Version", "2025-11-25")]))
        for id in 1...2 {
            try await channel.writeInbound(HTTPServerRequestPart.head(head))
            try await channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(string: #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"homekit_status","arguments":{}}}"#)))
            try await channel.writeInbound(HTTPServerRequestPart.end(nil))
        }
        try await Self.eventually { await registry.calls >= 1 }
        await registry.releaseAll()
        var statuses: [HTTPResponseStatus] = []
        while statuses.count < 2 {
            let part = try await channel.waitForOutboundWrite(as: HTTPServerResponsePart.self)
            if case .head(let response) = part { statuses.append(response.status) }
        }
        XCTAssertEqual(statuses, [.ok, .tooManyRequests], "With a limit of 1 the second in-flight request is refused")
        let calls = await registry.calls
        XCTAssertEqual(calls, 1)
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }

    // MARK: Production codecs with raw HTTP bytes (4059799145)

    private func productionChannel(_ server: MCPServer) async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel()
        try await channel.pipeline.configureHTTPServerPipeline().flatMap {
            channel.pipeline.addHandler(MCPHTTPHandler(server: server))
        }.get()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 9090)).get()
        return channel
    }

    private static func request(_ method: String, headers: [String: String] = [:], body: String = "") -> String {
        var lines = ["\(method) /mcp HTTP/1.1", "Host: 127.0.0.1", "Content-Type: application/json", "Accept: application/json, text/event-stream"]
        lines += headers.map { "\($0.key): \($0.value)" }
        if method != "GET" { lines.append("Content-Length: \(body.utf8.count)") }
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    /// Reads encoded response bytes until `done` holds for the accumulated text.
    private func readWire(_ channel: NIOAsyncTestingChannel, until done: (String) -> Bool) async throws -> String {
        var text = ""
        for _ in 0..<400 {
            while let buffer = try await channel.readOutbound(as: ByteBuffer.self) { text += String(buffer: buffer) }
            if done(text) { return text }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for response bytes; got: \(text)")
        return text
    }

    private static func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    func testProductionPipelineFramesResponsesFromRawBytes() async throws {
        let server = MCPServer(homeKitReady: true, toolRegistry: HomeClawMCPToolRegistry.test(status: "ok"))
        let channel = try await productionChannel(server)

        try await channel.writeInbound(ByteBuffer(string: Self.request("POST", body: Self.initialize)))
        let initText = try await readWire(channel) { $0.contains("\"serverInfo\"") }
        XCTAssertTrue(initText.hasPrefix("HTTP/1.1 200 OK\r\n"))
        let sessionLine = try XCTUnwrap(initText.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("mcp-session-id:") })
        let session = sessionLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
        let follow = ["Mcp-Session-Id": session, "MCP-Protocol-Version": "2025-11-25"]

        // Two pipelined requests in one write: FIFO responses, 202 has an empty body.
        let pipelined = Self.request("POST", headers: follow, body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            + Self.request("POST", headers: follow, body: #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        try await channel.writeInbound(ByteBuffer(string: pipelined))
        let both = try await readWire(channel) { $0.contains("\"id\":2") }
        let accepted = try XCTUnwrap(both.range(of: "HTTP/1.1 202 Accepted\r\n"))
        let ping = try XCTUnwrap(both.range(of: "HTTP/1.1 200 OK\r\n"))
        XCTAssertLessThan(accepted.lowerBound, ping.lowerBound, "Responses must stay in request order")
        let ackHead = String(both[accepted.lowerBound..<ping.lowerBound])
        XCTAssertTrue(ackHead.lowercased().contains("content-length: 0\r\n"), ackHead)
        XCTAssertFalse(ackHead.lowercased().contains("transfer-encoding"), ackHead)

        // DELETE: 200 with an explicit empty body.
        try await channel.writeInbound(ByteBuffer(string: Self.request("DELETE", headers: follow)))
        let deleted = try await readWire(channel) { $0.contains("\r\n\r\n") }
        XCTAssertTrue(deleted.hasPrefix("HTTP/1.1 200 OK\r\n"), deleted)
        XCTAssertTrue(deleted.lowercased().contains("content-length: 0\r\n"), deleted)

        // Body limit enforced from the declared length, before any body arrives.
        try await channel.writeInbound(ByteBuffer(string: "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nAccept: application/json\r\nContent-Length: 2000000\r\n\r\n"))
        let tooLarge = try await readWire(channel) { $0.contains("\r\n\r\n") }
        XCTAssertTrue(tooLarge.hasPrefix("HTTP/1.1 413 Payload Too Large\r\n"), tooLarge)
        // The declared 2 MB body never arrives, so the decoder reports a truncated
        // stream on close; that is the expected end of this connection.
        _ = try? await channel.finish(acceptAlreadyClosed: true)
    }

    // MARK: HTTP descriptor advertises only what HTTP allows (4059799150)

    func testHTTPAccessoryDescriptorOmitsControlOnlyFields() async throws {
        let server = MCPServer(homeKitReady: true)
        let headers = try await Self.open(server)
        let body = Data(#"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#.utf8)
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: body))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(response.bodyData)) as? [String: Any])
        let tools = try XCTUnwrap((object["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let accessory = try XCTUnwrap(tools.first { $0["name"] as? String == "homekit_accessories" })
        let properties = try XCTUnwrap((accessory["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        for removed in ["characteristic", "value", "service_type", "service_name", "service_id", "service_index", "verify"] {
            XCTAssertNil(properties[removed], removed)
        }
        for kept in ["action", "home_id", "room", "accessory_id", "query", "category", "no_refresh"] {
            XCTAssertNotNil(properties[kept], kept)
        }
        let description = try XCTUnwrap(accessory["description"] as? String)
        XCTAssertFalse(description.contains("or control"), description)
        XCTAssertTrue(description.contains("Read-only"), description)

        // The canonical (stdio) descriptor is unchanged.
        let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: ToolHandlers.allToolsJSON) as? [[String: Any]])
        let canonicalAccessory = try XCTUnwrap(canonical.first { $0["name"] as? String == "homekit_accessories" })
        let canonicalProperties = try XCTUnwrap((canonicalAccessory["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNotNil(canonicalProperties["characteristic"])
        XCTAssertTrue((canonicalAccessory["description"] as? String)?.contains("control") == true)
    }
}
