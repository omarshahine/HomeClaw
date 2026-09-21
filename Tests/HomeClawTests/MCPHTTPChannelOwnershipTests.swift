import XCTest
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
import NIOEmbedded
@testable import HomeClaw

private actor SuspendedOwnershipRegistry: MCPToolRegistry {
    nonisolated var toolsJSON: Data { Data(#"[{"name":"homekit_status"}]"#.utf8) }
    private(set) var entered = false
    private var continuation: CheckedContinuation<Data, Never>?
    func call(name: String, arguments: Data) async -> Data {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: Data("{}".utf8)); continuation = nil }
}

/// Exercises MCPHTTPHandler.channelInactive, not just its bookkeeping helper.
/// The registry is controlled and never reaches HomeKit; no listener is bound.
final class MCPHTTPChannelOwnershipTests: XCTestCase {
    private func session(_ server: MCPServer) async throws -> String {
        let created = await server.sessionStore.create()
        return try XCTUnwrap(created?.id)
    }

    private func headers(_ session: String, stream: Bool = true) -> HTTPHeaders {
        HTTPHeaders([("Host", "127.0.0.1"), ("Accept", stream ? "text/event-stream" : "application/json"),
                     ("Content-Type", "application/json"), ("Mcp-Session-Id", session),
                     ("MCP-Protocol-Version", MCPServer.latestProtocolVersion)])
    }

    private func channel(_ server: MCPServer) async throws -> NIOAsyncTestingChannel {
        let channel = await NIOAsyncTestingChannel(handler: MCPHTTPHandler(server: server))
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 9090)).get()
        return channel
    }

    private func sendGET(_ channel: NIOAsyncTestingChannel, session: String) async throws {
        try await channel.writeInbound(HTTPServerRequestPart.head(HTTPRequestHead(version: .http1_1, method: .GET, uri: "/mcp", headers: headers(session))))
        try await channel.writeInbound(HTTPServerRequestPart.end(nil))
    }

    private func waitForConnected(_ channel: NIOAsyncTestingChannel) async throws {
        let head = try await channel.waitForOutboundWrite(as: HTTPServerResponsePart.self)
        guard case .head(let response) = head else { return XCTFail("Expected SSE response head") }
        XCTAssertEqual(response.status, .ok)
        let body = try await channel.waitForOutboundWrite(as: HTTPServerResponsePart.self)
        guard case .body(.byteBuffer(let buffer)) = body else { return XCTFail("Expected connected frame") }
        XCTAssertEqual(String(buffer: buffer), ": connected\n\n")
    }

    private func eventually(_ predicate: @escaping @Sendable () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for lifecycle state", file: file, line: line)
    }

    private func assertStillOwned(_ ownership: SSEStreamOwnership, server: MCPServer,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        // Check throughout a bounded observation window: cleanup is dispatched in a Task.
        for _ in 0..<40 {
            let current = await server.testSSEOwnerships
            XCTAssertTrue(current.contains(ownership), "Disconnect retired another connection's SSE", file: file, line: line)
            if !current.contains(ownership) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testPOSTDisconnectPreservesAnotherConnectionsSSE() async throws {
        let registry = SuspendedOwnershipRegistry()
        let server = MCPServer(toolRegistry: registry)
        let id = try await session(server)
        let streamChannel = try await channel(server)
        let postChannel = try await channel(server)
        try await sendGET(streamChannel, session: id)
        try await waitForConnected(streamChannel)
        let snapshot = await server.testSSEOwnerships
        let ownership = try XCTUnwrap(snapshot.first)

        try await postChannel.writeInbound(HTTPServerRequestPart.head(HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp", headers: headers(id, stream: false))))
        let body = ByteBuffer(string: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"homekit_status","arguments":{}}}"#)
        try await postChannel.writeInbound(HTTPServerRequestPart.body(body))
        try await postChannel.writeInbound(HTTPServerRequestPart.end(nil))
        try await eventually { await registry.entered }
        try await postChannel.close().get() // Real channelInactive while the POST is in flight.
        try await assertStillOwned(ownership, server: server)
        await registry.release()
        try await streamChannel.close().get()
        try await eventually { await server.testSSEOwnerships.isEmpty }
        _ = try await postChannel.finish(acceptAlreadyClosed: true)
        _ = try await streamChannel.finish(acceptAlreadyClosed: true)
        await server.stop()
    }

    func testOldSSEDisconnectPreservesReplacement() async throws {
        let server = MCPServer(toolRegistry: HomeClawMCPToolRegistry.test(status: "unused"))
        let id = try await session(server)
        let oldChannel = try await channel(server)
        try await sendGET(oldChannel, session: id)
        try await waitForConnected(oldChannel)
        let oldSnapshot = await server.testSSEOwnerships
        let oldOwnership = try XCTUnwrap(oldSnapshot.first)

        // Hold the old event loop so its completion cannot retire bookkeeping
        // before channelInactive. Replacement is created on the independent actor.
        let entered = expectation(description: "old loop held")
        let release = DispatchSemaphore(value: 0)
        oldChannel.eventLoop.execute {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            oldChannel.close(promise: nil)
        }
        await fulfillment(of: [entered], timeout: 2)
        let replacement = await server.handleHTTPRequest(HTTPRequest(method: "GET", headers: Dictionary(uniqueKeysWithValues: headers(id).map { ($0.name, $0.value) })))
        let ownership = try XCTUnwrap(replacement.sseOwnership)
        XCTAssertNotEqual(oldOwnership, ownership)
        release.signal()
        try await oldChannel.closeFuture.get()
        try await assertStillOwned(ownership, server: server)
        await server.cleanupSSE(for: ownership)
        _ = try await oldChannel.finish(acceptAlreadyClosed: true)
        await server.stop()
    }

    func testOwnerDisconnectRemovesItsSSEButKeepsSession() async throws {
        let server = MCPServer(toolRegistry: HomeClawMCPToolRegistry.test(status: "unused"))
        let id = try await session(server)
        let owner = try await channel(server)
        try await sendGET(owner, session: id)
        try await waitForConnected(owner)
        let before = await server.testSSEOwnerships
        XCTAssertEqual(before.count, 1)
        try await owner.close().get()
        try await eventually { await server.testSSEOwnerships.isEmpty }
        let sessionCount = await server.sessionStore.count
        XCTAssertEqual(sessionCount, 1)
        _ = try await owner.finish(acceptAlreadyClosed: true)
        await server.stop()
    }

    func testDisconnectBeforeSSERegistrationDoesNotLeakOwnership() async throws {
        let server = MCPServer(toolRegistry: HomeClawMCPToolRegistry.test(status: "unused"))
        let id = try await session(server)
        let owner = try await channel(server)
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/mcp", headers: headers(id))
        let entered = expectation(description: "request started with event loop held")
        let release = DispatchSemaphore(value: 0)
        owner.eventLoop.execute {
            owner.pipeline.fireChannelRead(HTTPServerRequestPart.head(head))
            owner.pipeline.fireChannelRead(HTTPServerRequestPart.end(nil))
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            owner.close(promise: nil)
        }
        await fulfillment(of: [entered], timeout: 2)
        try await eventually { await !server.testSSEOwnerships.isEmpty }
        release.signal() // channelInactive runs before queued markSSEActive.
        try await owner.closeFuture.get()
        try await eventually { await server.testSSEOwnerships.isEmpty }
        _ = try await owner.finish(acceptAlreadyClosed: true)
        await server.stop()
    }
}
