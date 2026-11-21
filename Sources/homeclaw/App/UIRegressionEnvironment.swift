import Foundation

/// Explicit opt-in for synthetic onboarding UI tests. A separate Debug app
/// identity is mandatory, so the installed app and its defaults stay untouched.
enum UIRegressionEnvironment {
    static let enabled = isEnabled(bundleIdentifier: Bundle.main.bundleIdentifier,
                                   arguments: ProcessInfo.processInfo.arguments)

    static func isEnabled(bundleIdentifier: String?, arguments: [String]) -> Bool {
        #if DEBUG
        bundleIdentifier == "com.shahine.homeclaw.ui-regression"
            && arguments.contains("--ui-test-demo")
            && arguments.contains("--ui-test-isolated")
        #else
        false
        #endif
    }

    static let configDirectory: URL? = {
        guard enabled else { return nil }
        // A UUID permits repeat launches of the same fixture without accepting
        // an arbitrary filesystem path from the launch environment.
        let token = UUID(uuidString: ProcessInfo.processInfo.environment["HOMECLAW_UI_FIXTURE"] ?? "")
            ?? UUID()
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("homeclaw-ui-\(token.uuidString)", isDirectory: true)
    }()

    static func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) -> Int {
        guard enabled, let value = Int(ProcessInfo.processInfo.environment[key] ?? ""), range.contains(value)
        else { return fallback }
        return value
    }
}
