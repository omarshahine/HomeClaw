import HomeKit
import XCTest
@testable import HomeClaw

/// HMService has no public initializer. These synthetic values exercise the same
/// selector used by both createAutomation's dry-run and live button path.
final class InputEventServiceSelectionTests: XCTestCase {
    private struct Service: Equatable {
        let id: String
        let type: String
        let index: Int?
    }

    private let doorbell = Service(id: "doorbell", type: HMServiceTypeDoorbell, index: nil)
    private let button1 = Service(id: "button-1", type: HMServiceTypeStatelessProgrammableSwitch, index: 1)
    private let button2 = Service(id: "button-2", type: HMServiceTypeStatelessProgrammableSwitch, index: 2)
    private let camera = Service(id: "camera", type: HMServiceTypeCameraRTPStreamManagement, index: 1)
    private let motion = Service(id: "motion", type: HMServiceTypeMotionSensor, index: nil)

    private func select(_ services: [Service], index: Int? = nil) throws -> Service {
        try HomeKitManager.selectInputEventService(
            from: services, accessoryName: "Test Accessory", serviceIndex: index,
            serviceType: { $0.type }, labelIndex: { $0.index })
    }

    func testLoneDoorbellNeedsNoIndex() throws {
        XCTAssertEqual(try select([doorbell]), doorbell)
    }

    func testCameraAndMotionServicesDoNotMakeDoorbellAmbiguous() throws {
        XCTAssertEqual(try select([camera, motion, doorbell]), doorbell)
    }

    func testExistingSingleProgrammableSwitchStillWorks() throws {
        XCTAssertEqual(try select([button1]), button1)
        XCTAssertEqual(try select([button1], index: 1), button1)
    }

    func testMultipleSwitchesUseLabelIndexNotArrayPosition() throws {
        XCTAssertEqual(try select([button2, camera, button1], index: 1), button1)
        XCTAssertEqual(try select([button2, camera, button1], index: 2), button2)
    }

    func testMultipleSwitchesRequireIndex() {
        XCTAssertThrowsError(try select([button1, button2])) { error in
            XCTAssertTrue(error.localizedDescription.contains("--service-index"))
        }
    }

    func testUnknownIndexDoesNotFallBackToLoneSwitch() {
        XCTAssertThrowsError(try select([button1], index: 2)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Available: 1"))
        }
    }

    func testUnlabeledDoorbellDoesNotInventIndexOneOrUseCameraIndex() {
        XCTAssertThrowsError(try select([camera, doorbell], index: 1))
    }

    func testMixedServicesNeedUniqueLabelIndex() throws {
        XCTAssertThrowsError(try select([doorbell, button1]))
        XCTAssertEqual(try select([doorbell, button1], index: 1), button1)
    }

    func testDoorbellWithActualLabelIndexCanBeSelected() throws {
        let labeled = Service(id: "labeled-doorbell", type: HMServiceTypeDoorbell, index: 3)
        XCTAssertEqual(try select([button1, labeled], index: 3), labeled)
    }

    func testDuplicateIndicesNeverPickFirstService() {
        let duplicate = Service(id: "duplicate", type: button1.type, index: 1)
        let labeledDoorbell = Service(id: "labeled-doorbell", type: HMServiceTypeDoorbell, index: 1)
        for services in [[button1, duplicate], [button1, labeledDoorbell], [labeledDoorbell, button1]] {
            XCTAssertThrowsError(try select(services, index: 1)) { error in
                XCTAssertTrue(error.localizedDescription.contains("cannot select a unique button"))
            }
        }
    }

    func testMultipleUnlabeledDoorbellsAreNotSilentlySelected() {
        let second = Service(id: "second-doorbell", type: HMServiceTypeDoorbell, index: nil)
        XCTAssertThrowsError(try select([doorbell, second])) { error in
            XCTAssertTrue(error.localizedDescription.contains("No unique service_index"))
        }
    }

    func testUnrelatedOrEmptyServicesAreRejected() {
        for services in [[], [camera, motion]] {
            XCTAssertThrowsError(try select(services)) { error in
                XCTAssertTrue(error.localizedDescription.contains("no programmable switch or doorbell services"))
            }
        }
    }
}
