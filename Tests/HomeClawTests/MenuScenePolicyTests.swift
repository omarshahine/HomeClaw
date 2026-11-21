import XCTest
@testable import HomeClaw

final class MenuScenePolicyTests: XCTestCase {
    func testAllActionTargetsSelected() {
        XCTAssertNil(MenuScenePolicy.disabledReason(actionAccessoryIDs: ["a", "b"], allowedIDs: ["a", "b"]))
    }

    func testExcludedTargetIsBlocked() {
        XCTAssertNotNil(MenuScenePolicy.disabledReason(actionAccessoryIDs: ["b"], allowedIDs: ["a"]))
    }

    func testMixedSelectedAndExcludedCannotRunPartialScene() {
        XCTAssertNotNil(MenuScenePolicy.disabledReason(actionAccessoryIDs: ["a", "b"], allowedIDs: ["a"]))
    }

    func testUnresolvedTargetIsBlocked() {
        XCTAssertNotNil(MenuScenePolicy.disabledReason(actionAccessoryIDs: [nil], allowedIDs: ["a"]))
    }

    func testMixedSelectedAndUnresolvedCannotRunPartialScene() {
        XCTAssertNotNil(MenuScenePolicy.disabledReason(actionAccessoryIDs: ["a", nil], allowedIDs: ["a"]))
    }

    func testUnavailableSelectionFailsClosed() {
        XCTAssertNotNil(MenuScenePolicy.disabledReason(actionAccessoryIDs: ["a"], allowedIDs: nil))
    }

    func testEmptySelectionAllowsNoDeviceActions() {
        XCTAssertNotNil(MenuScenePolicy.disabledReason(actionAccessoryIDs: ["a"], allowedIDs: []))
    }

    func testZeroActionsDoNotImplyAnExcludedDevice() {
        XCTAssertNil(MenuScenePolicy.disabledReason(actionAccessoryIDs: [], allowedIDs: nil))
        XCTAssertNil(MenuScenePolicy.disabledReason(actionAccessoryIDs: [], allowedIDs: []))
    }
}
