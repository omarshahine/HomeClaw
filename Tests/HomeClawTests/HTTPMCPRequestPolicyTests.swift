import XCTest
@testable import HomeClaw

final class HTTPMCPRequestPolicyTests: XCTestCase {
    func testAcceptsLoopbackHostsAndAbsentOrigin() throws {
        XCTAssertNoThrow(try HTTPMCPRequestPolicy.validate(host: "127.0.0.1:9090", origin: nil, bindHost: "127.0.0.1"))
        XCTAssertNoThrow(try HTTPMCPRequestPolicy.validate(host: "[::1]:9090", origin: nil, bindHost: "::1"))
        XCTAssertNoThrow(try HTTPMCPRequestPolicy.validate(host: "localhost", origin: nil, bindHost: "127.0.0.1"))
    }

    func testAcceptsLoopbackOrigin() throws {
        XCTAssertNoThrow(try HTTPMCPRequestPolicy.validate(
            host: "127.0.0.1:9090", origin: "http://localhost:9090", bindHost: "127.0.0.1"))
        XCTAssertNoThrow(try HTTPMCPRequestPolicy.validate(
            host: "[::1]:9090", origin: "http://[::1]:9090", bindHost: "::1"))
    }

    func testRejectsPublicHostsAndOrigins() {
        let cases: [(String, String?, String)] = [
            ("evil.example:9090", nil, "127.0.0.1"),
            ("127.0.0.1:9090", "https://evil.example", "127.0.0.1"),
            ("127.0.0.1:9090", "not an origin", "127.0.0.1"),
            ("localhost:9090", nil, "::1"),
        ]
        for (host, origin, bindHost) in cases {
            XCTAssertThrowsError(try HTTPMCPRequestPolicy.validate(
                host: host, origin: origin, bindHost: bindHost))
        }
    }

    func testPolicyErrorsDoNotEchoBodiesOrCredentials() {
        let body = "password=super-secret bearer=top-secret"
        XCTAssertThrowsError(try HTTPMCPRequestPolicy.validate(
            host: "evil.example?body=\(body)", origin: "https://evil.example/\(body)", bindHost: "127.0.0.1")) { error in
            let description = String(describing: error)
            XCTAssertFalse(description.contains(body))
            XCTAssertFalse(description.contains("super-secret"))
            XCTAssertFalse(description.contains("top-secret"))
        }
    }
}
