import HomeKit
import XCTest
@testable import HomeClaw

/// Display As mapping (issue #132). HMService has no public initializer, so these
/// exercise the service-type-keyed helpers `setDisplayAs` and `get` are built on.
final class DisplayAsTests: XCTestCase {
    func testOnlySwitchAndOutletSupportDisplayAs() {
        XCTAssertEqual(AccessoryModel.ownDisplayAs(serviceType: HMServiceTypeSwitch), "switch")
        XCTAssertEqual(AccessoryModel.ownDisplayAs(serviceType: HMServiceTypeOutlet), "outlet")
        for type in [HMServiceTypeLightbulb, HMServiceTypeFan, HMServiceTypeStatelessProgrammableSwitch] {
            XCTAssertNil(AccessoryModel.ownDisplayAs(serviceType: type), type)
            XCTAssertTrue(AccessoryModel.associatedServiceType(forDisplayAs: "light", serviceType: type) == nil, type)
        }
    }

    func testLightAndFanMapToAssociatedServiceTypes() {
        for type in [HMServiceTypeSwitch, HMServiceTypeOutlet] {
            XCTAssertEqual(AccessoryModel.associatedServiceType(forDisplayAs: "light", serviceType: type), .some(HMServiceTypeLightbulb))
            XCTAssertEqual(AccessoryModel.associatedServiceType(forDisplayAs: "Light", serviceType: type), .some(HMServiceTypeLightbulb))
            XCTAssertEqual(AccessoryModel.associatedServiceType(forDisplayAs: "FAN", serviceType: type), .some(HMServiceTypeFan))
        }
    }

    func testOwnTypeAndDefaultClearTheAssociation() {
        let cleared: String?? = .some(nil)
        XCTAssertEqual(AccessoryModel.associatedServiceType(forDisplayAs: "switch", serviceType: HMServiceTypeSwitch), cleared)
        XCTAssertEqual(AccessoryModel.associatedServiceType(forDisplayAs: "outlet", serviceType: HMServiceTypeOutlet), cleared)
        XCTAssertEqual(AccessoryModel.associatedServiceType(forDisplayAs: "default", serviceType: HMServiceTypeSwitch), cleared)
        XCTAssertEqual(AccessoryModel.associatedServiceType(forDisplayAs: "DEFAULT", serviceType: HMServiceTypeOutlet), cleared)
    }

    func testTheOtherPowerTypeAndUnknownValuesAreRejected() {
        // The Home app offers a switch Switch/Light/Fan and an outlet Outlet/Light/Fan.
        XCTAssertTrue(AccessoryModel.associatedServiceType(forDisplayAs: "outlet", serviceType: HMServiceTypeSwitch) == nil)
        XCTAssertTrue(AccessoryModel.associatedServiceType(forDisplayAs: "switch", serviceType: HMServiceTypeOutlet) == nil)
        XCTAssertTrue(AccessoryModel.associatedServiceType(forDisplayAs: "thermostat", serviceType: HMServiceTypeSwitch) == nil)
        XCTAssertTrue(AccessoryModel.associatedServiceType(forDisplayAs: "", serviceType: HMServiceTypeSwitch) == nil)
        // One contract with the published schema enum: no undocumented aliases.
        XCTAssertTrue(AccessoryModel.associatedServiceType(forDisplayAs: "lightbulb", serviceType: HMServiceTypeSwitch) == nil)
        XCTAssertTrue(AccessoryModel.associatedServiceType(forDisplayAs: "none", serviceType: HMServiceTypeSwitch) == nil)
    }

    func testEffectiveDisplayAsReportsAssociationOrOwnType() {
        XCTAssertEqual(AccessoryModel.displayAs(serviceType: HMServiceTypeSwitch, associatedServiceType: nil), "switch")
        XCTAssertEqual(AccessoryModel.displayAs(serviceType: HMServiceTypeSwitch, associatedServiceType: HMServiceTypeLightbulb), "light")
        XCTAssertEqual(AccessoryModel.displayAs(serviceType: HMServiceTypeOutlet, associatedServiceType: HMServiceTypeFan), "fan")
        XCTAssertNil(AccessoryModel.displayAs(serviceType: HMServiceTypeLightbulb, associatedServiceType: nil))
    }
}
