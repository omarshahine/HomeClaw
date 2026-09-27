import HomeKit
import XCTest
@testable import HomeClaw

/// Service-group kind rules (issue #134): the Home app only groups one kind of
/// accessory, and a switch or outlet displayed as a light or fan counts as that.
final class GroupKindTests: XCTestCase {
    func testKindIsTheServiceCategory() {
        XCTAssertEqual(AccessoryModel.groupKind(serviceType: HMServiceTypeLightbulb, associatedServiceType: nil), "lightbulb")
        XCTAssertEqual(AccessoryModel.groupKind(serviceType: HMServiceTypeSwitch, associatedServiceType: nil), "switch")
        XCTAssertEqual(AccessoryModel.groupKind(serviceType: HMServiceTypeOutlet, associatedServiceType: nil), "outlet")
    }

    func testDisplayAsDecidesTheKindOfASwitchOrOutlet() {
        XCTAssertEqual(AccessoryModel.groupKind(serviceType: HMServiceTypeSwitch, associatedServiceType: HMServiceTypeLightbulb), "lightbulb")
        XCTAssertEqual(AccessoryModel.groupKind(serviceType: HMServiceTypeOutlet, associatedServiceType: HMServiceTypeFan), "fan")
    }

    func testAssociatedTypeIsIgnoredOnServicesWithoutDisplayAs() {
        // Only switches and outlets carry a meaningful association; anything else
        // stays its own kind even if a stale value is present.
        XCTAssertEqual(AccessoryModel.groupKind(serviceType: HMServiceTypeLightbulb, associatedServiceType: HMServiceTypeFan), "lightbulb")
    }

    func testSupplementaryServicesCannotBeMembers() {
        for type in [HMServiceTypeAccessoryInformation, HMServiceTypeBattery, HMServiceTypeLabel] {
            XCTAssertNil(AccessoryModel.groupKind(serviceType: type, associatedServiceType: nil), type)
        }
    }

    func testMixedKindsAreReportedSortedAndDeduplicated() {
        XCTAssertNil(AccessoryModel.mixedKinds([]))
        XCTAssertNil(AccessoryModel.mixedKinds(["lightbulb"]))
        XCTAssertNil(AccessoryModel.mixedKinds(["lightbulb", "lightbulb", "lightbulb"]))
        XCTAssertEqual(AccessoryModel.mixedKinds(["switch", "lightbulb", "switch"]), ["lightbulb", "switch"])
    }

    func testARelayDisplayedAsALightGroupsWithBulbs() {
        let kinds = [
            AccessoryModel.groupKind(serviceType: HMServiceTypeLightbulb, associatedServiceType: nil),
            AccessoryModel.groupKind(serviceType: HMServiceTypeSwitch, associatedServiceType: HMServiceTypeLightbulb),
        ].compactMap { $0 }
        XCTAssertNil(AccessoryModel.mixedKinds(kinds))
        // …but a plain switch next to a bulb is mixed.
        XCTAssertEqual(AccessoryModel.mixedKinds(["lightbulb", "switch"]), ["lightbulb", "switch"])
    }
}
