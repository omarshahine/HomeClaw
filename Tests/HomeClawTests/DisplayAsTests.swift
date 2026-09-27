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
            XCTAssertNil(AccessoryModel.associatedServiceType(forDisplayAs: "light", serviceType: type), type)
        }
    }

    func testLightAndFanMapToAssociatedServiceTypes() {
        for type in [HMServiceTypeSwitch, HMServiceTypeOutlet] {
            XCTAssertEqual(AccessoryModel.associatedServiceType(forDisplayAs: "light", serviceType: type), .some(HMServiceTypeLightbulb))
            XCTAssertEqual(AccessoryModel.associatedServiceType(forDisplayAs: "Lightbulb", serviceType: type), .some(HMServiceTypeLightbulb))
            XCTAssertEqual(AccessoryModel.associatedServiceType(forDisplayAs: "FAN", serviceType: type), .some(HMServiceTypeFan))
        }
    }

    func testOwnTypeAndDefaultClearTheAssociation() {
        let cleared: String?? = .some(nil)
        XCTAssertEqual(AccessoryModel.associatedServiceType(forDisplayAs: "switch", serviceType: HMServiceTypeSwitch), cleared)
        XCTAssertEqual(AccessoryModel.associatedServiceType(forDisplayAs: "outlet", serviceType: HMServiceTypeOutlet), cleared)
        XCTAssertEqual(AccessoryModel.associatedServiceType(forDisplayAs: "default", serviceType: HMServiceTypeSwitch), cleared)
        XCTAssertEqual(AccessoryModel.associatedServiceType(forDisplayAs: "none", serviceType: HMServiceTypeOutlet), cleared)
    }

    func testTheOtherPowerTypeAndUnknownValuesAreRejected() {
        // The Home app offers a switch Switch/Light/Fan and an outlet Outlet/Light/Fan.
        XCTAssertNil(AccessoryModel.associatedServiceType(forDisplayAs: "outlet", serviceType: HMServiceTypeSwitch))
        XCTAssertNil(AccessoryModel.associatedServiceType(forDisplayAs: "switch", serviceType: HMServiceTypeOutlet))
        XCTAssertNil(AccessoryModel.associatedServiceType(forDisplayAs: "thermostat", serviceType: HMServiceTypeSwitch))
        XCTAssertNil(AccessoryModel.associatedServiceType(forDisplayAs: "", serviceType: HMServiceTypeSwitch))
    }

    func testEffectiveDisplayAsReportsAssociationOrOwnType() {
        XCTAssertEqual(AccessoryModel.displayAs(serviceType: HMServiceTypeSwitch, associatedServiceType: nil), "switch")
        XCTAssertEqual(AccessoryModel.displayAs(serviceType: HMServiceTypeSwitch, associatedServiceType: HMServiceTypeLightbulb), "light")
        XCTAssertEqual(AccessoryModel.displayAs(serviceType: HMServiceTypeOutlet, associatedServiceType: HMServiceTypeFan), "fan")
        XCTAssertNil(AccessoryModel.displayAs(serviceType: HMServiceTypeLightbulb, associatedServiceType: nil))
    }
}
