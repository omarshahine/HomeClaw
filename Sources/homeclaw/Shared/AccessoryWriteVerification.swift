import Foundation

/// The write callback succeeded but did not establish what the device did.
/// Verification polls reads only. Its clock and read adapter are injectable so
/// bridge timing, failed reads, and the deadline can be tested without HomeKit.
enum AccessoryWriteVerification {
    enum Observation: Equatable {
        case matches
        case differs(String)
        case unavailable
    }

    enum Outcome: Equatable {
        case confirmed
        case unconfirmed(lastRead: String?)
    }

    @MainActor
    static func confirm(
        bridged: Bool,
        elapsed: () -> Duration,
        sleep: (Duration) async throws -> Void,
        read: (TimeInterval) async -> Observation
    ) async -> Outcome {
        let budget: Duration = .seconds(bridged ? 5 : 3)
        let interval: Duration = .milliseconds(bridged ? 500 : 250)
        let attempts = bridged ? 10 : 3
        var lastRead: String?
        for index in 0..<attempts {
            guard !Task.isCancelled, elapsed() < budget else { break }
            if index > 0 {
                do { try await sleep(min(interval, budget - elapsed())) }
                catch { break }
            }
            let remaining = budget - elapsed()
            guard !Task.isCancelled, remaining > .zero else { break }
            let parts = remaining.components
            let timeout = min(1.5, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
            let observation = await read(timeout)
            guard !Task.isCancelled, elapsed() <= budget else { break }
            switch observation {
            case .matches: return .confirmed
            case .differs(let value): lastRead = value
            case .unavailable: break
            }
        }
        return .unconfirmed(lastRead: lastRead)
    }
}

enum AccessoryWriteFailure: LocalizedError {
    case failed(String)
    case unconfirmed(String)

    var code: String {
        switch self {
        case .failed: "write_failed"
        case .unconfirmed: "write_unconfirmed"
        }
    }

    var errorDescription: String? {
        switch self {
        case .failed(let detail):
            "Write failed: \(detail)"
        case .unconfirmed(let detail):
            "Write unconfirmed: HomeKit accepted the write, but \(detail). Check the current state with a fresh read before trying another write."
        }
    }
}
