import Foundation

enum AppConfig {
    static let bundleID = "com.hadm.homeclaw"
    static let appName = "HomeClaw"

    /// Returns the real user home directory, bypassing the sandbox container.
    /// In a sandboxed Mac Catalyst app, `NSHomeDirectory()` returns the container path
    /// (~/Library/Containers/com.shahine.homeclaw/Data/). This function uses the POSIX
    /// password database to get the actual home directory (/Users/<username>/).
    /// Needed for accessing external app configs (Claude Desktop, Claude Code, OpenClaw).
    static let realHomeDirectory: String = {
        if let pw = getpwuid(getuid()) {
            return String(cString: pw.pointee.pw_dir)
        }
        return NSHomeDirectory()
    }()
    static let version: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    }()

    static let build: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }()

    // App Group identifier shared between main app and helper for sandboxed IPC.
    static let appGroupID = "group.com.shahine.homeclaw"

    // Socket path — uses App Group container for sandboxed Catalyst builds.
    // The Catalyst sandbox prevents creating sockets in /tmp (EPERM),
    // so we always prefer the app group container when available.
    static let socketPath: String = {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            return container.appendingPathComponent("homeclaw.sock").path
        }
        return "/tmp/homeclaw.sock"
    }()

    // Native MCP HTTP listener configuration. Only the port is overrideable for tests/development.
    static let mcpBindHost = HTTPMCPConfiguration.defaultBindHost
    static let mcpEndpoint: String = {
        "http://\(mcpBindHost):\(mcpPort)/mcp"
    }()
    static let mcpPort: Int = {
        guard let value = ProcessInfo.processInfo.environment["HOMECLAW_MCP_PORT"],
              let port = Int(value), (1...65535).contains(port) else {
            return HTTPMCPConfiguration.defaultPort
        }
        return port
    }()

    // UserDefaults keys
    static let launchAtLoginKey = "launchAtLogin"
}
