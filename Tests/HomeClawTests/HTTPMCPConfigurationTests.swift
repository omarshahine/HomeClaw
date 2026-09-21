import XCTest
@testable import HomeClaw

final class HTTPMCPConfigurationTests: XCTestCase {
    func testDefaultPortIs9090() {
        XCTAssertEqual(HTTPMCPConfiguration.defaultPort, 9090)
    }

    func testExplicitPortIsPreserved() {
        XCTAssertEqual(HTTPMCPConfiguration(port: 19090, bindHost: "127.0.0.1").port, 19090)
    }

    func testLoopbackAddressesAreAccepted() throws {
        XCTAssertNoThrow(try HTTPMCPConfiguration(port: 9090, bindHost: "127.0.0.1").validateLoopbackBind())
        XCTAssertNoThrow(try HTTPMCPConfiguration(port: 9090, bindHost: "::1").validateLoopbackBind())
    }

    func testNonLoopbackAddressesAreRejected() {
        for host in ["0.0.0.0", "::", "192.168.1.10"] {
            XCTAssertThrowsError(try HTTPMCPConfiguration(port: 9090, bindHost: host).validateLoopbackBind(), host)
        }
    }
}
