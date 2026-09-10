import Foundation
import Testing
@testable import HomeClawFreshness

@Suite("Characteristic read attestation")
struct CharacteristicReadAttestationTests {
    private let date = Date(timeIntervalSince1970: 1_789_048_800.125)
    private let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test("Success is timestamped; failure is not")
    func wireAttestation() {
        let success = CharacteristicReadAttestation.completed(succeeded: true, at: date)
        let failure = CharacteristicReadAttestation.completed(succeeded: false, at: date)

        #expect(success.wireValue["succeeded"] as? Bool == true)
        #expect(success.wireValue["observed_at"] as? String == "2026-09-10T14:00:00.125Z")
        #expect(failure.wireValue["succeeded"] as? Bool == false)
        #expect(failure.wireValue["observed_at"] == nil)
    }

    @Test("A complete report builds the attested producer payload")
    func completeProducerPayload() {
        var report = AccessoryReadReport()
        report.record(
            characteristicID: first,
            attestation: .completed(succeeded: true, at: date)
        )
        let characteristic = report.attesting(
            ["name": "contact_state", "value": "0"],
            characteristicID: first
        )
        let payload = report.applyingFreshness(to: [
            "services": [["characteristics": [characteristic]]]
        ])

        #expect(payload["refreshed"] as? Bool == true)
        #expect(payload["read_attempted"] as? Int == 1)
        #expect((characteristic["read"] as? [String: Any])?["succeeded"] as? Bool == true)

        let stale = AccessoryReadReport.applyingNoRefresh(to: [:])
        #expect(stale["refreshed"] as? Bool == false)
        #expect(stale["read_attempted"] as? Int == 0)
        #expect(stale["read_succeeded"] as? Int == 0)
    }

    @Test("Only a non-empty all-success report is fresh")
    func aggregateContract() {
        var report = AccessoryReadReport()
        #expect(!report.allSucceeded)
        #expect(report.applyingFreshness(to: [:])["refreshed"] as? Bool == false)

        report.record(
            characteristicID: first,
            attestation: .completed(succeeded: true, at: date)
        )
        report.record(
            characteristicID: second,
            attestation: .completed(succeeded: false, at: date)
        )

        #expect(report.attemptedCount == 2)
        #expect(report.succeededCount == 1)
        #expect(!report.allSucceeded)
        #expect(report.attestation(for: first)?.observedAt == date)
        #expect(report.wireSummary["read_attempted"] as? Int == 2)
        #expect(report.wireSummary["read_succeeded"] as? Int == 1)
        #expect(report.wireSummary["refreshed"] as? Bool == false)
    }
}
