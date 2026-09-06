import XCTest
@testable import HomeClaw

final class StreamableHTTPTransportTests: XCTestCase {
    private let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}"
    private let protocolVersion = MCPServer.supportedProtocolVersion
    private var headers: [String: String] { ["Content-Type": "application/json", "Accept": "application/json"] }
    private func send(_ server: MCPServer, _ request: HTTPRequest) async -> HTTPResponse { await server.handleHTTPRequest(request) }
    private func sessionHeaders(for id: String, accept: String = "application/json") -> [String: String] {
        ["Content-Type": "application/json", "Accept": accept, "Mcp-Session-Id": id, "MCP-Protocol-Version": protocolVersion]
    }

    func testInitializeCreatesSessionAndReturnsSessionHeader() async {
        let response = await send(MCPServer(homeKitReady: false), HTTPRequest(method: "POST", headers: headers, body: Data(json.utf8)))
        XCTAssertEqual(response.statusCode, 200); XCTAssertNotNil(response.header("Mcp-Session-Id")); XCTAssertTrue(response.bodyString?.contains("protocolVersion") == true)
    }

    func testInvalidInitializeDoesNotAllocateSession() async throws {
        let server = MCPServer()
        let badJSON = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
        let bad = await send(server, HTTPRequest(method: "POST", headers: headers, body: Data(badJSON.utf8)))
        XCTAssertEqual(bad.statusCode, 400); XCTAssertNil(bad.header("Mcp-Session-Id"))
        let c0 = await server.sessionStore.count; XCTAssertEqual(c0, 0)
        // initialize notification with invalid params: still 202, no allocation (notifications never create)
        let notifBad = "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{}}"
        let notif = await send(server, HTTPRequest(method: "POST", headers: headers, body: Data(notifBad.utf8)))
        XCTAssertEqual(notif.statusCode, 202)
        let c1 = await server.sessionStore.count; XCTAssertEqual(c1, 0)
    }

    func testSessionCapReturns429() async throws {
        let store = StreamableHTTPSessionStore(ttl: 3600, maxSessions: 1)
        let server = MCPServer(sessionStore: store)
        let first = await send(server, HTTPRequest(method: "POST", headers: headers, body: Data(json.utf8)))
        XCTAssertEqual(first.statusCode, 200)
        let second = await send(server, HTTPRequest(method: "POST", headers: headers, body: Data(json.utf8)))
        XCTAssertEqual(second.statusCode, 429)
        let cnt = await store.count; XCTAssertEqual(cnt, 1)
    }

    func testRequestsRequireTheirOwnValidSession() async {
            let server = MCPServer(); let initialize = await send(server, HTTPRequest(method: "POST", headers: headers, body: Data(json.utf8)))
            let id = initialize.header("Mcp-Session-Id")!
            let list = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}".utf8)
            let missing = await send(server, HTTPRequest(method: "POST", headers: headers, body: list)); XCTAssertEqual(missing.statusCode, 400)
            let validHeaders = sessionHeaders(for: id)
            let valid = await send(server, HTTPRequest(method: "POST", headers: validHeaders, body: list)); XCTAssertEqual(valid.statusCode, 200)
            let unknownHeaders = sessionHeaders(for: "unknown")
            let unknown = await send(server, HTTPRequest(method: "POST", headers: unknownHeaders, body: list)); XCTAssertEqual(unknown.statusCode, 404)
        }

    func testNotificationIsAcceptedAndGetAndDeleteAreSessionScoped() async throws {
            let server = MCPServer(); let initialize = await send(server, HTTPRequest(method: "POST", headers: headers, body: Data(json.utf8)))
            let id = try XCTUnwrap(initialize.header("Mcp-Session-Id"))
            let sessionHeadersJSON = self.sessionHeaders(for: id, accept: "application/json")
            let sessionHeadersSSE = self.sessionHeaders(for: id, accept: "text/event-stream")
            let notification = Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8)
            let accepted = await send(server, HTTPRequest(method: "POST", headers: sessionHeadersJSON, body: notification)); XCTAssertEqual(accepted.statusCode, 202); XCTAssertNil(accepted.bodyData)
            let sse = await send(server, HTTPRequest(method: "GET", headers: sessionHeadersSSE)); XCTAssertEqual(sse.statusCode, 200); XCTAssertEqual(sse.header("Content-Type"), "text/event-stream"); XCTAssertNotNil(sse.stream)
            // initial SSE chunk is delivered via stream, not bodyData
            if let stream = sse.stream {
                var it = stream.makeAsyncIterator(); let first = await it.next()
                XCTAssertEqual(first, Data(": connected\n\n".utf8))
            }
            let deleted = await send(server, HTTPRequest(method: "DELETE", headers: sessionHeadersSSE)); XCTAssertEqual(deleted.statusCode, 200)
            let gone = await send(server, HTTPRequest(method: "GET", headers: sessionHeadersSSE)); XCTAssertEqual(gone.statusCode, 404)
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
