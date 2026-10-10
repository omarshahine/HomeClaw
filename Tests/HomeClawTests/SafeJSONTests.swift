import XCTest
@testable import HomeClaw

/// Issue #147: an accessory reporting a characteristic value of infinity made
/// `JSONSerialization` raise an Objective-C exception on the main actor, which
/// wedged the main queue and hung every later socket request. These cases raise
/// (and so crash this test process) if any of them reaches `JSONSerialization`
/// unsanitized.
final class SafeJSONTests: XCTestCase {
    private func decode(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testNonFiniteNumbersAreWrittenAsNull() throws {
        let payload: [String: Any] = [
            "power": Double.infinity,
            "voltage": -Double.infinity,
            "current": Double.nan,
            "watts": Float.infinity,
        ]
        XCTAssertFalse(JSONSerialization.isValidJSONObject(payload), "precondition: raw payload would raise")
        let decoded = try decode(SafeJSON.data(withJSONObject: payload))
        for key in payload.keys {
            XCTAssertTrue(decoded[key] is NSNull, key)
        }
    }

    func testNestedNonFiniteValuesInAnAccessoryDetailAreSanitized() throws {
        let detail: [String: Any] = [
            "success": true,
            "data": [
                "name": "Outlet",
                "services": [
                    ["characteristics": [["name": "power_consumption", "value": Double.infinity]]],
                ],
            ],
        ]
        let decoded = try decode(SafeJSON.data(withJSONObject: detail, options: [.sortedKeys]))
        let data = try XCTUnwrap(decoded["data"] as? [String: Any])
        let services = try XCTUnwrap(data["services"] as? [[String: Any]])
        let characteristics = try XCTUnwrap(services.first?["characteristics"] as? [[String: Any]])
        XCTAssertTrue(characteristics.first?["value"] is NSNull)
        XCTAssertEqual(characteristics.first?["name"] as? String, "power_consumption")
    }

    func testFiniteNumbersStringsAndBoolsAreUnchanged() throws {
        let payload: [String: Any] = ["on": true, "off": false, "level": 42, "temp": 21.5, "name": "Lamp", "none": NSNull()]
        let decoded = try decode(SafeJSON.data(withJSONObject: payload))
        XCTAssertEqual(decoded["on"] as? Bool, true)
        XCTAssertEqual(decoded["off"] as? Bool, false)
        XCTAssertEqual(decoded["level"] as? Int, 42)
        XCTAssertEqual(decoded["temp"] as? Double, 21.5)
        XCTAssertEqual(decoded["name"] as? String, "Lamp")
        XCTAssertTrue(decoded["none"] is NSNull)
    }

    func testANonJSONValueReturnsNilInsteadOfRaising() {
        XCTAssertNil(SafeJSON.data(withJSONObject: ["when": Date()]))
    }
}
