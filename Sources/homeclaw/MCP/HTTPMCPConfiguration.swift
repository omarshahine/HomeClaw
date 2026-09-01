import Foundation

struct HTTPMCPConfiguration: Equatable, Sendable {
    static let defaultPort = 9090
    static let defaultBindHost = "127.0.0.1"

    let port: Int
    let bindHost: String
    let sessionTTL: TimeInterval

    init(port: Int = defaultPort, bindHost: String = defaultBindHost, sessionTTL: TimeInterval = 3600) {
        self.port = port
        self.bindHost = bindHost
        self.sessionTTL = sessionTTL
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
