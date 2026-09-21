import Foundation
import NIOCore

struct HTTPMCPConfiguration: Equatable, Sendable {
    static let defaultPort = 9090
    static let defaultBindHost = "127.0.0.1"
    static let defaultMaxSessions = 128
    static let defaultMaxInflightPerChannel = 16
    static let defaultMaxConnections = 64
    static let defaultMaxConcurrentToolCalls = 32
    static let defaultIdleTimeout: TimeAmount = .seconds(60)

    let port: Int
    let bindHost: String
    let sessionTTL: TimeInterval
    let maxSessions: Int
    let maxInflightPerChannel: Int
    /// Concurrent TCP connections accepted; beyond this new ones are closed.
    let maxConnections: Int
    /// Tool dispatches in flight across all connections; beyond this `tools/call` fails fast.
    let maxConcurrentToolCalls: Int
    /// A connection with no request in flight and no SSE stream is closed after
    /// this long without reading anything.
    let idleTimeout: TimeAmount

    init(port: Int = defaultPort, bindHost: String = defaultBindHost, sessionTTL: TimeInterval = 3600, maxSessions: Int = defaultMaxSessions, maxInflightPerChannel: Int = defaultMaxInflightPerChannel, maxConnections: Int = defaultMaxConnections, maxConcurrentToolCalls: Int = defaultMaxConcurrentToolCalls, idleTimeout: TimeAmount = defaultIdleTimeout) {
        self.port = port
        self.bindHost = bindHost
        self.sessionTTL = sessionTTL
        self.maxSessions = maxSessions
        self.maxInflightPerChannel = maxInflightPerChannel
        self.maxConnections = maxConnections
        self.maxConcurrentToolCalls = maxConcurrentToolCalls
        self.idleTimeout = idleTimeout
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
