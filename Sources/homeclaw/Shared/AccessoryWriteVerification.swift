import Foundation

/// The write callback succeeded but did not establish what the device did.
/// Verification polls reads only. Its clock and read adapter are injectable so
/// bridge timing, failed reads, and the deadline can be tested without HomeKit.
enum AccessoryWriteVerification {
    enum Observation: Equatable {
        case matches(String)
        case differs(String)
        case unavailable
    }

    enum Outcome: Equatable {
        case confirmed(value: String)
        case unconfirmed(lastRead: String?)
    }

    /// Read the live model property only when the live read succeeded.
    /// Cache and notification values must not stand in for a failed read.
    static func observe<Value>(
        succeeded: Bool,
        value: @autoclosure () -> Value?,
        matches: (Value) -> Bool,
        format: (Value) -> String
    ) -> Observation {
        guard succeeded, let current = value() else { return .unavailable }
        let formatted = format(current)
        return matches(current) ? .matches(formatted) : .differs(formatted)
    }

    /// Success fields for control. Only the explicitly observed target gets
    /// a verified value; the surrounding accessory summary is last-known.
    static func successFields(
        confirmedValue: String?,
        verificationRequested: Bool,
        lastKnownValue: @autoclosure () -> String?
    ) -> [String: Any] {
        var fields: [String: Any] = ["state_source": "last_known"]
        if let confirmedValue {
            fields["value"] = confirmedValue
            fields["verified"] = true
        } else {
            fields["value"] = lastKnownValue()
            fields["verification_skipped"] = verificationRequested ? "not_readable" : "disabled"
        }
        return fields
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
            case .matches(let value): return .confirmed(value: value)
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
