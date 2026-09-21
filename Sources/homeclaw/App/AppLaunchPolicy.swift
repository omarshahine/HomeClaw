import Foundation

/// App-hosted unit tests exercise services explicitly with controlled fixtures;
/// they must not also launch the user's real HomeKit/socket/menu-bar services.
enum AppLaunchPolicy {
    static func isUnitTestHost(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

    static var suppressLiveServices: Bool {
        #if DEBUG
        isUnitTestHost(environment: ProcessInfo.processInfo.environment)
            || NSClassFromString("XCTestCase") != nil
        #else
        false
        #endif
    }
}
