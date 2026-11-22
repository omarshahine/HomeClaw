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
    private var skippedUnmapped: Set<UUID> = []

    /// The standard HomeKit Accessory Protocol UUID namespace. Keep a strict
    /// live-read requirement for mapped types, standard types that have not
    /// been mapped yet, and unfamiliar identifier formats. Skip only an
    /// unmapped UUID outside that namespace (e.g. a vendor OTA characteristic).
    static func requiresLiveRead(characteristicType: String, isMapped: Bool) -> Bool {
        if isMapped { return true }
        guard let type = UUID(uuidString: characteristicType) else { return true }
        return type.uuidString.hasSuffix("-0000-1000-8000-0026BB765291")
    }

    mutating func skipUnmapped(characteristicID: UUID) {
        skippedUnmapped.insert(characteristicID)
    }

    var attemptedCount: Int { attestations.count }
    var succeededCount: Int { attestations.values.filter(\.succeeded).count }
    var allSucceeded: Bool { attemptedCount > 0 && succeededCount == attemptedCount }
    var wireSummary: [String: Any] {
        var summary: [String: Any] = [
            "refreshed": allSucceeded,
            "read_attempted": attemptedCount,
            "read_succeeded": succeededCount,
        ]
        if !skippedUnmapped.isEmpty { summary["read_skipped_unmapped"] = skippedUnmapped.count }
        return summary
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
        } else if skippedUnmapped.contains(characteristicID) {
            result["value_source"] = "last_known"
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
