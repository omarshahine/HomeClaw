import Foundation

enum AppConfig {
    static let bundleID = "com.shahine.homeclaw"
    static let appName = "HomeClaw"
    static let version: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    }()

    static let build: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }()

    // App Group identifier shared between main app and helper for sandboxed IPC.
    static let appGroupID = "group.com.shahine.homeclaw"

    // CLI Socket — uses App Group container when available (sandboxed builds),
    // falls back to /tmp for Developer ID / direct builds.
    static let socketPath: String = {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            let groupPath = container.appendingPathComponent("homeclaw.sock").path
            if FileManager.default.fileExists(atPath: groupPath) {
                return groupPath
            }
        }
        return "/tmp/homeclaw.sock"
    }()

    // UserDefaults keys
    static let launchAtLoginKey = "launchAtLogin"
}
