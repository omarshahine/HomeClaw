import OSLog

enum HelperLogger {
    static let app = Logger(subsystem: "com.shahine.homeclaw.helper", category: "app")
    static let homekit = Logger(subsystem: "com.shahine.homeclaw.helper", category: "homekit")
    static let socket = Logger(subsystem: "com.shahine.homeclaw.helper", category: "socket")
}
