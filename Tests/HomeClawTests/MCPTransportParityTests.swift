import XCTest
@testable import HomeClaw

@MainActor
final class MCPTransportParityTests: XCTestCase {
    func testCanonicalDescriptorsMatchNodeGeneratedFixture() throws {
        // The Node drift check compares this entire fixture AND the embedded Swift
        // JSON against the real lib/schemas.js export (not a hardcoded tool list).
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mcp-tools", withExtension: "json"))
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? NSArray
        let actual = try JSONSerialization.jsonObject(with: ToolHandlers.allToolsJSON) as? NSArray
        XCTAssertEqual(try XCTUnwrap(actual), try XCTUnwrap(expected))
        XCTAssertEqual(HomeClawMCPToolRegistry.shared.toolsJSON, ToolHandlers.allToolsJSON)
        let tools = try XCTUnwrap(actual as? [[String: Any]])
        XCTAssertFalse(tools.isEmpty)
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(ToolHandlers.allToolNames, names)
        XCTAssertEqual(Set(names).count, tools.count)
    }

    func testHTTPToolsListOmitsMutatingAccessoryActionButCanonicalSchemaRetainsIt() async throws {
        let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: ToolHandlers.allToolsJSON) as? [[String: Any]])
        let canonicalAccessory = try XCTUnwrap(canonical.first { $0["name"] as? String == "homekit_accessories" })
        XCTAssertTrue(try actions(in: canonicalAccessory).contains("control"))

        let registry = RecordingParityRegistry()
        let server = MCPServer(toolRegistry: registry)
        let headers = try await initialize(server)
        let tools = try await advertisedTools(server, headers: headers)
        let httpAccessory = try XCTUnwrap(tools.first { $0["name"] as? String == "homekit_accessories" })
        XCTAssertEqual(try actions(in: httpAccessory), ["list", "get", "search"])
        let calls = await registry.calls
        XCTAssertTrue(calls.isEmpty, "tools/list must not execute any handler")
    }

    func testEveryHTTPAdvertisedToolRoutesToInjectedRegistryWithoutHomeKit() async throws {
        // This proves transport/registry wiring, NOT execution of native HomeKit
        // handlers. Even a policy regression can only reach this inert recorder.
        let registry = RecordingParityRegistry()
        let server = MCPServer(homeKitReady: true, toolRegistry: registry)
        let headers = try await initialize(server)
        let tools = try await advertisedTools(server, headers: headers)
        XCTAssertFalse(tools.isEmpty)
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            let arguments = name == "homekit_accessories" ? ["action": "list"] : [:]
            let request = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": ["name": name, "arguments": arguments]
            ])
            let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: request))
            XCTAssertEqual(response.statusCode, 200)
            let body = try object(response)
            XCTAssertNil(body["error"])
            let result = try XCTUnwrap(body["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            let text = try XCTUnwrap(content.first?["text"] as? String)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(payload["recordedTool"] as? String, name)
            let calls = await registry.calls
            let call = try XCTUnwrap(calls.last)
            XCTAssertEqual(call.name, name)
            let received = try JSONSerialization.jsonObject(with: call.arguments) as? [String: String]
            XCTAssertEqual(received, arguments)
        }
        let calls = await registry.calls
        XCTAssertEqual(calls.map(\.name), tools.compactMap { $0["name"] as? String })
    }

    func testHTTPRejectsUnadvertisedToolsAndMutatingActionsBeforeRegistry() async throws {
        let registry = RecordingParityRegistry()
        let server = MCPServer(toolRegistry: registry)
        let headers = try await initialize(server)
        let advertised = try await advertisedTools(server, headers: headers).compactMap { $0["name"] as? String }
        let hidden = ToolHandlers.allToolNames.filter { !advertised.contains($0) }
        XCTAssertFalse(hidden.isEmpty)
        let probes = hidden.map { ($0, [String: String]()) } + [
            ("homekit_accessories", ["action": "control"]),
            ("homekit_accessories", ["action": "future_action"]),
            ("future_tool", [:])
        ]
        for (name, arguments) in probes {
            let request = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 4, "method": "tools/call",
                "params": ["name": name, "arguments": arguments]
            ])
            let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: request))
            XCTAssertNotNil(try object(response)["error"], "Must reject \(name) \(arguments)")
        }
        let calls = await registry.calls
        XCTAssertTrue(calls.isEmpty, "Denied calls must never reach the dispatcher")
    }

    private func initialize(_ server: MCPServer) async throws -> [String: String] {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"parity-test","version":"1.0"}}}"#.utf8)
        let headers = ["Content-Type": "application/json", "Accept": "application/json"]
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: body))
        let session = try XCTUnwrap(response.header("Mcp-Session-Id"))
        return headers.merging(["Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.latestProtocolVersion]) { _, value in value }
    }

    private func advertisedTools(_ server: MCPServer, headers: [String: String]) async throws -> [[String: Any]] {
        let body = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#.utf8)
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: body))
        let result = try XCTUnwrap(try object(response)["result"] as? [String: Any])
        return try XCTUnwrap(result["tools"] as? [[String: Any]])
    }

    private func object(_ response: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(response.bodyData)) as? [String: Any])
    }

    private func actions(in tool: [String: Any]) throws -> [String] {
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let action = try XCTUnwrap(properties["action"] as? [String: Any])
        return try XCTUnwrap(action["enum"] as? [String])
    }
}

private actor RecordingParityRegistry: MCPToolRegistry {
    struct Call: Sendable {
        let name: String
        let arguments: Data
    }
    nonisolated let toolsJSON = ToolHandlers.allToolsJSON
    private(set) var calls: [Call] = []

    func call(name: String, arguments: Data) async -> Data {
        calls.append(Call(name: name, arguments: arguments))
        return (try? JSONSerialization.data(withJSONObject: ["recordedTool": name])) ?? Data()
    }
}
