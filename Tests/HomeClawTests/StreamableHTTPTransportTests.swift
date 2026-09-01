import XCTest
@testable import HomeClaw

final class StreamableHTTPTransportTests: XCTestCase {
    private let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
    private let headers = ["Content-Type": "application/json", "Accept": "application/json"]
    private func send(_ server: MCPServer, _ request: HTTPRequest) async -> HTTPResponse { await server.handleHTTPRequest(request) }

    func testInitializeCreatesSessionAndReturnsSessionHeader() async {
        let response = await send(MCPServer(homeKitReady: false), HTTPRequest(method: "POST", headers: headers, body: Data(json.utf8)))
        XCTAssertEqual(response.statusCode, 200); XCTAssertNotNil(response.header("Mcp-Session-Id")); XCTAssertTrue(response.bodyString?.contains("protocolVersion") == true)
    }

    func testRequestsRequireTheirOwnValidSession() async {
        let server = MCPServer(); let initialize = await send(server, HTTPRequest(method: "POST", headers: headers, body: Data(json.utf8)))
        let id = initialize.header("Mcp-Session-Id")!
        let list = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}".utf8)
        let missing = await send(server, HTTPRequest(method: "POST", headers: headers, body: list)); XCTAssertEqual(missing.statusCode, 400)
        let validHeaders = headers.merging(["Mcp-Session-Id": id]) { _, new in new }
        let valid = await send(server, HTTPRequest(method: "POST", headers: validHeaders, body: list)); XCTAssertEqual(valid.statusCode, 200)
        let unknownHeaders = headers.merging(["Mcp-Session-Id": "unknown"]) { _, new in new }
        let unknown = await send(server, HTTPRequest(method: "POST", headers: unknownHeaders, body: list)); XCTAssertEqual(unknown.statusCode, 404)
    }

    func testNotificationIsAcceptedAndGetAndDeleteAreSessionScoped() async throws {
        let server = MCPServer(); let initialize = await send(server, HTTPRequest(method: "POST", headers: headers, body: Data(json.utf8)))
        let id = try XCTUnwrap(initialize.header("Mcp-Session-Id"))
        let sessionHeaders = headers.merging(["Mcp-Session-Id": id, "Accept": "text/event-stream"]) { _, new in new }
        let notification = Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8)
        let accepted = await send(server, HTTPRequest(method: "POST", headers: sessionHeaders, body: notification)); XCTAssertEqual(accepted.statusCode, 202); XCTAssertNil(accepted.bodyData)
        let sse = await send(server, HTTPRequest(method: "GET", headers: sessionHeaders)); XCTAssertEqual(sse.statusCode, 200); XCTAssertEqual(sse.header("Content-Type"), "text/event-stream"); XCTAssertTrue(sse.bodyString?.hasSuffix("\n\n") == true)
        let deleted = await send(server, HTTPRequest(method: "DELETE", headers: sessionHeaders)); XCTAssertEqual(deleted.statusCode, 200)
        let gone = await send(server, HTTPRequest(method: "GET", headers: sessionHeaders)); XCTAssertEqual(gone.statusCode, 404)
    }

    func testMixedCaseAcceptMediaTypeIsAccepted() async {
        let response = await send(MCPServer(homeKitReady: false), HTTPRequest(method: "POST", headers: ["Content-Type": "application/json", "Accept": "Application/JSON"], body: Data(json.utf8)))
        XCTAssertEqual(response.statusCode, 200)
    }

    func testZeroQualityAcceptMediaTypeIsRejected() async {
        let response = await send(MCPServer(homeKitReady: false), HTTPRequest(method: "POST", headers: ["Content-Type": "application/json", "Accept": "Application/JSON; Q=0; charset=utf-8"], body: Data(json.utf8)))
        XCTAssertEqual(response.statusCode, 406)
    }

    func testPostRejectsEventStreamOnlyAccept() async {
        let response = await send(MCPServer(homeKitReady: false), HTTPRequest(method: "POST", headers: ["Content-Type": "application/json", "Accept": "text/event-stream"], body: Data(json.utf8)))
        XCTAssertEqual(response.statusCode, 406)
    }

    func testPostAcceptsMixedMediaTypesWhenJSONIsAcceptable() async {
        let response = await send(MCPServer(homeKitReady: false), HTTPRequest(method: "POST", headers: ["Content-Type": "application/json", "Accept": "text/event-stream; q=1, application/json; q=0.5"], body: Data(json.utf8)))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.header("Content-Type"), "application/json; charset=utf-8")
    }

    func testRejectsProtocolAndMediaErrorsBeforeExecution() async {
        let server = MCPServer()
        let badType = ["Content-Type": "text/plain", "Accept": "application/json"]; let typeResponse = await send(server, HTTPRequest(method: "POST", headers: badType, body: Data(json.utf8))); XCTAssertEqual(typeResponse.statusCode, 415)
        let badAccept = ["Content-Type": "application/json", "Accept": "text/plain"]; let acceptResponse = await send(server, HTTPRequest(method: "POST", headers: badAccept, body: Data(json.utf8))); XCTAssertEqual(acceptResponse.statusCode, 406)
        let malformed = await send(server, HTTPRequest(method: "POST", headers: headers, body: Data("{bad".utf8))); XCTAssertEqual(malformed.statusCode, 400)
        let method = await send(server, HTTPRequest(method: "PUT", headers: headers)); XCTAssertEqual(method.statusCode, 405)
        let path = await send(server, HTTPRequest(method: "POST", uri: "/wrong", headers: headers, body: Data(json.utf8))); XCTAssertEqual(path.statusCode, 404)
    }
}
