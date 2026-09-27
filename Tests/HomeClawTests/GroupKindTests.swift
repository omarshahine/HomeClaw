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
        for type in [HMServiceTypeAccessoryInformation, HMServiceTypeBattery, HMServiceTypeLabel, HMServiceTypeSlats] {
            XCTAssertNil(AccessoryModel.groupKind(serviceType: type, associatedServiceType: nil), type)
        }
    }

    func testOnlyKindsTheHomeAppGroupsAreGroupable() {
        // Buttons, sensors, locks, cameras, climate and media never form a Home app
        // group; allowing them would build groups the Home app can't render.
        let ungroupable = [
            HMServiceTypeStatelessProgrammableSwitch, HMServiceTypeMotionSensor, HMServiceTypeLeakSensor,
            HMServiceTypeContactSensor, HMServiceTypeLockMechanism, HMServiceTypeThermostat,
            HMServiceTypeHeaterCooler, HMServiceTypeSecuritySystem, HMServiceTypeTelevision,
            HMServiceTypeGarageDoorOpener, HMServiceTypeDoorbell,
        ]
        for type in ungroupable {
            XCTAssertNil(AccessoryModel.groupKind(serviceType: type, associatedServiceType: nil), type)
        }
        XCTAssertEqual(AccessoryModel.groupableKinds, ["lightbulb", "switch", "outlet", "fan", "window_covering"])
    }

    func testFansAndBlindsGroupByKind() {
        XCTAssertEqual(AccessoryModel.groupKind(serviceType: HMServiceTypeFan, associatedServiceType: nil), "fan")
        XCTAssertEqual(AccessoryModel.groupKind(serviceType: HMServiceTypeVentilationFan, associatedServiceType: nil), "fan")
        XCTAssertEqual(AccessoryModel.groupKind(serviceType: HMServiceTypeWindowCovering, associatedServiceType: nil), "window_covering")
    }

    func testAnUngroupableAssociationFallsBackToTheOwnKind() {
        // Another app could associate a switch with a non-light/fan type; the switch
        // then still groups as a switch rather than becoming ungroupable.
        XCTAssertEqual(AccessoryModel.groupKind(serviceType: HMServiceTypeSwitch, associatedServiceType: HMServiceTypeMotionSensor), "switch")
        XCTAssertEqual(AccessoryModel.groupKind(serviceType: HMServiceTypeOutlet, associatedServiceType: "not-a-service-type"), "outlet")
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
