import Foundation

/// A stable, deliberately minimal liveness/readiness representation.
struct HTTPMCPHealthResponse: Equatable, Sendable {
    let listenerReady: Bool
    let homeKitReady: Bool

    var statusCode: Int { listenerReady && homeKitReady ? 200 : 503 }

    /// Serialized manually to keep key order and output stable across runtimes.
    var bodyString: String {
        "{\"homekit_ready\":\(homeKitReady ? "true" : "false"),\"listener_ready\":\(listenerReady ? "true" : "false"),\"status\":\"\(listenerReady && homeKitReady ? "ready" : "not_ready")\"}"
    }

    var bodyData: Data { Data(bodyString.utf8) }
}
