import Foundation

/// The request policy for the loopback-only HTTP listener.
enum HTTPMCPRequestPolicy {
    enum ValidationError: Error, Equatable {
        case invalidHost
        case nonLoopbackHost
        case hostDoesNotMatchBind
        case invalidOrigin
        case nonLoopbackOrigin
    }

    static func validate(host: String, origin: String?, bindHost: String) throws {
        guard let hostURL = URL(string: "http://\(host)"),
              hostURL.user == nil, hostURL.password == nil,
              hostURL.path.isEmpty || hostURL.path == "/",
              hostURL.query == nil, hostURL.fragment == nil,
              let hostName = hostURL.host?.lowercased()
        else { throw ValidationError.invalidHost }

        guard isLoopback(hostName) else { throw ValidationError.nonLoopbackHost }
        let normalizedBindHost = normalized(bindHost)
        let bindAllowsLocalhost = normalizedBindHost == "127.0.0.1" || normalizedBindHost == "localhost"
        guard hostName == normalizedBindHost || (bindAllowsLocalhost && hostName == "localhost")
        else { throw ValidationError.hostDoesNotMatchBind }

        guard let origin = origin else { return }
        guard let originURL = URL(string: origin),
              (originURL.scheme?.lowercased() == "http" || originURL.scheme?.lowercased() == "https"),
              originURL.user == nil, originURL.password == nil,
              originURL.path.isEmpty || originURL.path == "/",
              originURL.query == nil, originURL.fragment == nil,
              let originHost = originURL.host?.lowercased()
        else { throw ValidationError.invalidOrigin }
        guard isLoopback(originHost) else { throw ValidationError.nonLoopbackOrigin }
    }

    private static func normalized(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }

    private static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "::1", "localhost"].contains(host)
    }
}
