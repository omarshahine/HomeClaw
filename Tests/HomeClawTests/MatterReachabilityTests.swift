import XCTest
@testable import HomeClaw

/// Matter node ids and reachability events (#137). `HMAccessory` has no public
/// initializer, so these drive the plain-value helpers the HomeKit paths use.
final class MatterNodeIDFormatTests: XCTestCase {
    func testZeroPadsToSixteenDigits() {
        XCTAssertEqual(AccessoryModel.matterNodeIDString(0x2A), "000000000000002A")
        XCTAssertEqual(AccessoryModel.matterNodeIDString(1), "0000000000000001")
    }

    func testUsesUppercaseHex() {
        XCTAssertEqual(AccessoryModel.matterNodeIDString(0xABCDEF), "0000000000ABCDEF")
        XCTAssertEqual(AccessoryModel.matterNodeIDString(0xdead_beef_cafe_f00d), "DEADBEEFCAFEF00D")
    }

    func testOmitsNilAndZero() {
        XCTAssertNil(AccessoryModel.matterNodeIDString(nil))
        XCTAssertNil(AccessoryModel.matterNodeIDString(0))
    }

    func testValuesAboveDoublePrecisionAreExact() {
        // 2^53 + 1 is the first integer a JSON double cannot represent.
        let aboveDouble: UInt64 = (1 << 53) + 1
        XCTAssertEqual(AccessoryModel.matterNodeIDString(aboveDouble), "0020000000000001")
        XCTAssertEqual(AccessoryModel.matterNodeIDString(.max), "FFFFFFFFFFFFFFFF")

        // The emitted string round-trips through JSON without precision loss.
        let data = try! JSONSerialization.data(
            withJSONObject: ["matter_node_id": AccessoryModel.matterNodeIDString(aboveDouble)!]
        )
        let decoded = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hex = decoded["matter_node_id"] as! String
        XCTAssertEqual(UInt64(hex, radix: 16), aboveDouble)
    }

    func testDemoAccessoryCarriesNodeID() {
        let demo = DemoFixtures.DemoAccessory(
            id: "demo", name: "Lamp", category: "lightbulb", roomID: "room",
            manufacturer: "Eve", matterNodeID: 0x2A
        )
        XCTAssertEqual(demo.summaryDict(roomName: "Living", state: [:])["matter_node_id"] as? String,
                       "000000000000002A")

        let nonMatter = DemoFixtures.DemoAccessory(
            id: "demo2", name: "Strip", category: "lightbulb", roomID: "room", manufacturer: "Hue"
        )
        XCTAssertNil(nonMatter.summaryDict(roomName: "Living", state: [:])["matter_node_id"])
    }
}

final class ReachabilityTrackerTests: XCTestCase {
    func testSeededValueSuppressesNoOpCallback() {
        var tracker = ReachabilityTracker()
        tracker.seed(accessoryID: "a", reachable: true)
        XCTAssertFalse(tracker.update(accessoryID: "a", reachable: true))
    }

    func testRealTransitionsAreReported() {
        var tracker = ReachabilityTracker()
        tracker.seed(accessoryID: "a", reachable: true)
        XCTAssertTrue(tracker.update(accessoryID: "a", reachable: false))
        XCTAssertFalse(tracker.update(accessoryID: "a", reachable: false), "duplicate unreachable")
        XCTAssertTrue(tracker.update(accessoryID: "a", reachable: true))
        XCTAssertEqual(tracker.lastKnownReachable(accessoryID: "a"), true)
    }

    func testUnseenAccessoryIsReported() {
        var tracker = ReachabilityTracker()
        XCTAssertTrue(tracker.update(accessoryID: "new", reachable: false))
        XCTAssertFalse(tracker.update(accessoryID: "new", reachable: false))
    }

    func testSeedDoesNotOverwriteKnownValue() {
        // A homes refresh must not hide a transition the delegate already recorded.
        var tracker = ReachabilityTracker()
        XCTAssertTrue(tracker.update(accessoryID: "a", reachable: false))
        tracker.seed(accessoryID: "a", reachable: true)
        XCTAssertEqual(tracker.lastKnownReachable(accessoryID: "a"), false)
        XCTAssertTrue(tracker.update(accessoryID: "a", reachable: true))
    }

    func testAccessoriesAreTrackedIndependently() {
        var tracker = ReachabilityTracker()
        tracker.seed(accessoryID: "a", reachable: true)
        tracker.seed(accessoryID: "b", reachable: true)
        XCTAssertTrue(tracker.update(accessoryID: "a", reachable: false))
        XCTAssertFalse(tracker.update(accessoryID: "b", reachable: true))
    }

    func testRetainDropsRemovedAccessories() {
        var tracker = ReachabilityTracker()
        tracker.seed(accessoryID: "a", reachable: true)
        tracker.seed(accessoryID: "gone", reachable: false)
        tracker.retain(accessoryIDs: ["a"])
        XCTAssertNil(tracker.lastKnownReachable(accessoryID: "gone"))
        XCTAssertEqual(tracker.lastKnownReachable(accessoryID: "a"), true)
    }
}

@MainActor
final class ReachabilityEventTests: XCTestCase {
    private func roundTrip(_ event: [String: Any]) throws -> [String: Any] {
        let data = try XCTUnwrap(SafeJSON.data(withJSONObject: event, options: [.sortedKeys]))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEventShape() throws {
        let timestamp = Date(timeIntervalSince1970: 1_790_000_000)
        let event = try roundTrip(HomeEventLogger.reachabilityEvent(
            accessoryID: "ACC-1", accessoryName: "B1", room: "Kids", reachable: false,
            matterNodeID: "000000000000002A", homeName: "Home", homeID: "HOME-1",
            timestamp: timestamp
        ))

        XCTAssertEqual(event["type"] as? String, "reachability_change")
        XCTAssertEqual(event["timestamp"] as? String, ISO8601DateFormatter().string(from: timestamp))
        XCTAssertEqual(event["reachable"] as? Bool, false)
        let accessory = try XCTUnwrap(event["accessory"] as? [String: Any])
        XCTAssertEqual(accessory["id"] as? String, "ACC-1")
        XCTAssertEqual(accessory["name"] as? String, "B1")
        XCTAssertEqual(accessory["room"] as? String, "Kids")
        XCTAssertEqual(accessory["matter_node_id"] as? String, "000000000000002A")
        let home = try XCTUnwrap(event["home"] as? [String: Any])
        XCTAssertEqual(home["name"] as? String, "Home")
        XCTAssertEqual(home["id"] as? String, "HOME-1")
        XCTAssertEqual(Set(event.keys), ["type", "timestamp", "accessory", "reachable", "home"])
    }

    func testOptionalFieldsAreOmitted() throws {
        let event = try roundTrip(HomeEventLogger.reachabilityEvent(
            accessoryID: "ACC-2", accessoryName: "Plug", room: nil, reachable: true
        ))
        XCTAssertEqual(event["reachable"] as? Bool, true)
        XCTAssertNil(event["home"])
        let accessory = try XCTUnwrap(event["accessory"] as? [String: Any])
        XCTAssertNil(accessory["matter_node_id"])
        XCTAssertTrue(accessory["room"] is NSNull, "room matches characteristic_change: null when unassigned")
    }

    func testEventTypeIsFilterable() {
        XCTAssertEqual(HomeEventLogger.EventType(rawValue: "reachability_change"), .reachabilityChange)
    }

    // MARK: - Webhook trigger matching

    private func trigger(
        accessoryID: String? = nil, characteristic: String? = nil, value: String? = nil
    ) -> HomeClawConfig.WebhookTrigger {
        var trigger = HomeClawConfig.WebhookTrigger.create(label: "t")
        trigger.accessoryID = accessoryID
        trigger.characteristic = characteristic
        trigger.value = value
        return trigger
    }

    private func matches(_ trigger: HomeClawConfig.WebhookTrigger, reachable: Bool, accessoryID: String = "ACC-1") -> Bool {
        HomeEventLogger.matchesTrigger(
            trigger, eventType: "reachability_change", accessoryID: accessoryID,
            characteristic: HomeEventLogger.reachabilityCharacteristic,
            value: reachable ? "true" : "false", sceneID: nil, sceneName: nil
        )
    }

    func testAccessoryOnlyTriggerIgnoresReachability() {
        // Existing accessory triggers must not start firing when a node flaps.
        XCTAssertFalse(matches(trigger(accessoryID: "ACC-1"), reachable: false))
    }

    func testReachableTriggerOptsIn() {
        XCTAssertTrue(matches(trigger(characteristic: "reachable"), reachable: false))
        XCTAssertTrue(matches(trigger(characteristic: "Reachable"), reachable: true))
    }

    func testReachableTriggerHonorsValueAndAccessory() {
        let dropsOnly = trigger(characteristic: "reachable", value: "false")
        XCTAssertTrue(matches(dropsOnly, reachable: false))
        XCTAssertFalse(matches(dropsOnly, reachable: true))

        let oneAccessory = trigger(accessoryID: "ACC-1", characteristic: "reachable")
        XCTAssertTrue(matches(oneAccessory, reachable: false))
        XCTAssertFalse(matches(oneAccessory, reachable: false, accessoryID: "ACC-2"))
    }

    func testCharacteristicTriggerStillMatchesCharacteristicChanges() {
        XCTAssertTrue(HomeEventLogger.matchesTrigger(
            trigger(characteristic: "contact_state"), eventType: "characteristic_change",
            accessoryID: "ACC-1", characteristic: "contact_state", value: "open",
            sceneID: nil, sceneName: nil
        ))
    }
}
