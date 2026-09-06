import XCTest
@testable import HomeClaw

final class MCPTransportParityTests: XCTestCase {
    func testCanonicalToolSetIncludesEveryNodeTool() throws {
        let expected = ["homekit_status", "homekit_accessories", "homekit_rooms", "homekit_scenes", "homekit_device_map", "homekit_manage", "homekit_config", "homekit_automations", "homekit_webhook", "homekit_events"]
        XCTAssertEqual(ToolHandlers.allToolNames, expected)
        let tools = try XCTUnwrap(JSONSerialization.jsonObject(with: ToolHandlers.allToolsJSON) as? [[String: Any]])
        XCTAssertTrue(tools.allSatisfy { $0["name"] != nil && $0["inputSchema"] != nil })
    }

    func testHTTPToolsListOmitsMutatingAccessoryActionButCanonicalSchemaRetainsIt() async throws {
        let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: ToolHandlers.allToolsJSON) as? [[String: Any]])
        let canonicalAccessory = try XCTUnwrap(canonical.first { $0["name"] as? String == "homekit_accessories" })
        let canonicalSchema = try XCTUnwrap(canonicalAccessory["inputSchema"] as? [String: Any])
        let canonicalProperties = try XCTUnwrap(canonicalSchema["properties"] as? [String: Any])
        let canonicalAction = try XCTUnwrap(canonicalProperties["action"] as? [String: Any])
        XCTAssertTrue((canonicalAction["enum"] as? [Any])?.contains { $0 as? String == "control" } == true)

        let server = MCPServer()
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: ["Content-Type": "application/json", "Accept": "application/json"], body: Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}".utf8)))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let headers = ["Content-Type": "application/json", "Accept": "application/json", "Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.supportedProtocolVersion]
        let list = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}".utf8)
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: list))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(response.bodyData)) as? [String: Any])
        let result = try XCTUnwrap(body["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let httpAccessory = try XCTUnwrap(tools.first { $0["name"] as? String == "homekit_accessories" })
        let httpSchema = try XCTUnwrap(httpAccessory["inputSchema"] as? [String: Any])
        let httpProperties = try XCTUnwrap(httpSchema["properties"] as? [String: Any])
        let httpAction = try XCTUnwrap(httpProperties["action"] as? [String: Any])
        XCTAssertFalse((httpAction["enum"] as? [Any])?.contains { $0 as? String == "control" } == true)
    }

    func testEveryAdvertisedToolHasNativeDispatch() async throws {
        let probes: [String: [String: Any]] = [
            "homekit_status": [:],
            "homekit_accessories": ["action": "unsupported"],
            "homekit_rooms": [:],
            "homekit_scenes": ["action": "unsupported"],
            "homekit_device_map": [:],
            "homekit_manage": ["action": "unsupported"],
            "homekit_config": ["action": "unsupported"],
            "homekit_automations": ["action": "unsupported"],
            "homekit_webhook": ["action": "unsupported"],
            "homekit_events": ["type": "unsupported"],
        ]
        for name in ToolHandlers.allToolNames {
            let arguments = try JSONSerialization.data(withJSONObject: probes[name] ?? [:])
            let result = await ToolHandlers.call(name: name, arguments: arguments)
            let text = String(decoding: result, as: UTF8.self)
            XCTAssertFalse(text.contains("Unknown tool"), "native dispatch returned Unknown tool for \(name)")
        }
    }

    func testNativeTransportUsesCanonicalToolsAndReadOnlyStatus() async throws {
        let registry = HomeClawMCPToolRegistry.test(status: "ok")
        let server = MCPServer(toolRegistry: registry)
        let headers = ["Content-Type": "application/json", "Accept": "application/json"]
        let initData = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}".utf8)
        let initResponse = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: headers, body: initData))
        let session = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let callData = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"homekit_status\",\"arguments\":{}}}".utf8)
        let callHeaders = headers.merging(["Mcp-Session-Id": session, "MCP-Protocol-Version": MCPServer.supportedProtocolVersion]) { _, value in value }
        let response = await server.handleHTTPRequest(HTTPRequest(method: "POST", headers: callHeaders, body: callData))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.bodyString?.contains("ok") == true)
    }
}
