import Foundation

struct CharacteristicReadAttestation: Equatable, Sendable {
    let succeeded: Bool
    let observedAt: Date?

    static func completed(succeeded: Bool, at date: Date = Date()) -> Self {
        Self(succeeded: succeeded, observedAt: succeeded ? date : nil)
    }

    var wireValue: [String: Any] {
        var value: [String: Any] = ["succeeded": succeeded]
        if let observedAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            value["observed_at"] = formatter.string(from: observedAt)
        }
        return value
    }
}

struct AccessoryReadReport: Equatable, Sendable {
    private var attestations: [UUID: CharacteristicReadAttestation] = [:]

    var attemptedCount: Int { attestations.count }
    var succeededCount: Int { attestations.values.filter(\.succeeded).count }
    var allSucceeded: Bool { attemptedCount > 0 && succeededCount == attemptedCount }
    var wireSummary: [String: Any] {
        [
            "refreshed": allSucceeded,
            "read_attempted": attemptedCount,
            "read_succeeded": succeededCount,
        ]
    }

    mutating func record(
        characteristicID: UUID,
        attestation: CharacteristicReadAttestation
    ) {
        attestations[characteristicID] = attestation
    }

    func attestation(for characteristicID: UUID) -> CharacteristicReadAttestation? {
        attestations[characteristicID]
    }

    func attesting(
        _ characteristic: [String: Any],
        characteristicID: UUID
    ) -> [String: Any] {
        var result = characteristic
        if let attestation = attestation(for: characteristicID) {
            result["read"] = attestation.wireValue
        }
        return result
    }

    func applyingFreshness(to detail: [String: Any]) -> [String: Any] {
        var result = detail
        result.merge(wireSummary) { _, freshness in freshness }
        return result
    }

    static func applyingNoRefresh(to detail: [String: Any]) -> [String: Any] {
        var result = detail
        result["refreshed"] = false
        result["read_attempted"] = 0
        result["read_succeeded"] = 0
        return result
    }
}
