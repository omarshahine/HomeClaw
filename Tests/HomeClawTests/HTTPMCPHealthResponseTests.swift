import XCTest
@testable import HomeClaw

final class HTTPMCPHealthResponseTests: XCTestCase {
    func testReadyResponseIsDeterministicAndSecretFree() throws {
        let first = HTTPMCPHealthResponse(listenerReady: true, homeKitReady: true)
        let second = HTTPMCPHealthResponse(listenerReady: true, homeKitReady: true)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.statusCode, 200)
        XCTAssertEqual(first.bodyString, "{\"homekit_ready\":true,\"listener_ready\":true,\"status\":\"ready\"}")
        XCTAssertFalse(first.bodyString.contains("token"))
        XCTAssertFalse(first.bodyString.contains("secret"))
    }

    func testListenerReadyButHomeKitUnavailableIsNotReady() {
        let response = HTTPMCPHealthResponse(listenerReady: true, homeKitReady: false)

        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(response.bodyString, "{\"homekit_ready\":false,\"listener_ready\":true,\"status\":\"not_ready\"}")
    }

    func testHealthResponseContainsOnlyReadinessFields() {
        let response = HTTPMCPHealthResponse(listenerReady: false, homeKitReady: false)

        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(response.bodyString, "{\"homekit_ready\":false,\"listener_ready\":false,\"status\":\"not_ready\"}")
        XCTAssertFalse(response.bodyString.contains("socket"))
        XCTAssertFalse(response.bodyString.contains("accessor"))
    }
}
