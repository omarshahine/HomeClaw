import OSLog

enum AppLogger {
    static let homekit = Logger(subsystem: AppConfig.bundleID, category: "homekit")
    static let cli = Logger(subsystem: AppConfig.bundleID, category: "cli")
    static let app = Logger(subsystem: AppConfig.bundleID, category: "app")
    static let helper = Logger(subsystem: AppConfig.bundleID, category: "helper")
}
