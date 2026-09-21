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
}
#endif
