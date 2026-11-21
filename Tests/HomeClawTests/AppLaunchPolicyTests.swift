import Foundation
#if !LIFECYCLE_STANDALONE
import XCTest
@testable import HomeClaw
#endif

private func verifyUnitTestLaunchPolicy() throws {
    struct Failure: Error {}
    guard AppLaunchPolicy.isUnitTestHost(environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]),
          AppLaunchPolicy.isUnitTestHost(environment: ["XCTestBundlePath": "/tmp/HomeClawTests.xctest"]),
          !AppLaunchPolicy.isUnitTestHost(environment: [:]) else { throw Failure() }
}

#if LIFECYCLE_STANDALONE
@main struct AppLaunchPolicyTestRunner {
    static func main() throws {
        try verifyUnitTestLaunchPolicy()
        print("PASS unitTestHostDetection")
    }
}
#else
final class AppLaunchPolicyTests: XCTestCase {
    func testUnitTestHostDetection() throws { try verifyUnitTestLaunchPolicy() }

    func testIsolatedUIRequiresSeparateIdentityAndBothFlags() {
        let flags = ["--ui-test-demo", "--ui-test-isolated"]
        XCTAssertTrue(UIRegressionEnvironment.isEnabled(bundleIdentifier: "com.shahine.homeclaw.ui-regression", arguments: flags))
        XCTAssertFalse(UIRegressionEnvironment.isEnabled(bundleIdentifier: "com.shahine.homeclaw", arguments: flags))
        XCTAssertFalse(UIRegressionEnvironment.isEnabled(bundleIdentifier: nil, arguments: flags))
        for arguments in [[], ["--ui-test-demo"], ["--ui-test-isolated"]] {
            XCTAssertFalse(UIRegressionEnvironment.isEnabled(bundleIdentifier: "com.shahine.homeclaw.ui-regression", arguments: arguments))
        }
    }
}
#endif
