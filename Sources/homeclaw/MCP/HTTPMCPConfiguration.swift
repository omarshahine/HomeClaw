import Foundation

struct HTTPMCPConfiguration: Equatable, Sendable {
    static let defaultPort = 9090
    static let defaultBindHost = "127.0.0.1"
    static let defaultMaxSessions = 128
    static let defaultMaxInflightPerChannel = 16

    let port: Int
    let bindHost: String
    let sessionTTL: TimeInterval
    let maxSessions: Int
    let maxInflightPerChannel: Int

    init(port: Int = defaultPort, bindHost: String = defaultBindHost, sessionTTL: TimeInterval = 3600, maxSessions: Int = defaultMaxSessions, maxInflightPerChannel: Int = defaultMaxInflightPerChannel) {
        self.port = port
        self.bindHost = bindHost
        self.sessionTTL = sessionTTL
        self.maxSessions = maxSessions
        self.maxInflightPerChannel = maxInflightPerChannel
    }

    enum ValidationError: Error, Equatable {
        case portOutOfRange
        case nonLoopbackBind(String)
    }

    func validateLoopbackBind() throws {
        guard (1...65535).contains(port) else { throw ValidationError.portOutOfRange }
        guard bindHost == "127.0.0.1" || bindHost == "::1" else {
            throw ValidationError.nonLoopbackBind(bindHost)
        }
    }
}
