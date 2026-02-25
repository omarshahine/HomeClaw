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

    // CLI Socket
    static let socketPath = "/tmp/homeclaw.sock"

    // UserDefaults keys
    static let launchAtLoginKey = "launchAtLogin"
}
