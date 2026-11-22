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

    @Test("Only valid unmapped vendor UUIDs are outside the required read scope")
    func supportedReadScope() {
        let vendor = "2E03020C-1234-4321-9999-123456789ABC"
        #expect(!AccessoryReadReport.requiresLiveRead(characteristicType: vendor, isMapped: false))
        #expect(AccessoryReadReport.requiresLiveRead(characteristicType: vendor, isMapped: true))
        #expect(AccessoryReadReport.requiresLiveRead(
            characteristicType: "000000cb-0000-1000-8000-0026bb765291", isMapped: false
        ))
        #expect(AccessoryReadReport.requiresLiveRead(characteristicType: "unknown-type", isMapped: false))
    }

    @Test("Two fresh channel reads survive skipped vendor rows; failure of either channel does not")
    func mixedReadReport() {
        let vendorA = UUID()
        let vendorB = UUID()
        var report = AccessoryReadReport()
        report.record(characteristicID: first, attestation: .completed(succeeded: true, at: date))
        report.record(characteristicID: second, attestation: .completed(succeeded: true, at: date))
        report.skipUnmapped(characteristicID: vendorA)
        report.skipUnmapped(characteristicID: vendorB)

        func payload(_ report: AccessoryReadReport) -> [String: Any] {
            let firstChannel = report.attesting(["name": "power", "value": "true"], characteristicID: first)
            let secondChannel = report.attesting(["name": "power", "value": "false"], characteristicID: second)
            let vendorService = [vendorA, vendorB].map {
                report.attesting(["name": "vendor", "value": "cached"], characteristicID: $0)
            }
            return report.applyingFreshness(to: ["services": [
                ["characteristics": [firstChannel]],
                ["characteristics": [secondChannel]],
                ["characteristics": vendorService],
            ]])
        }

        let result = payload(report)
        #expect(result["refreshed"] as? Bool == true)
        #expect(result["read_attempted"] as? Int == 2)
        #expect(result["read_succeeded"] as? Int == 2)
        #expect(result["read_skipped_unmapped"] as? Int == 2)
        #expect(AccessoryFreshnessContract.violation(in: result, allowStale: false) == nil)

        let services = result["services"] as? [[String: [[String: Any]]]]
        let vendorRows = services?.last?["characteristics"] ?? []
        #expect(vendorRows.count == 2)
        for row in vendorRows {
            #expect(row["value"] as? String == "cached")
            #expect(row["value_source"] as? String == "last_known")
            #expect(row["read"] == nil)
        }

        for failedID in [first, second] {
            var partial = report
            partial.record(characteristicID: failedID, attestation: .completed(succeeded: false, at: date))
            let failed = payload(partial)
            #expect(failed["read_attempted"] as? Int == 2)
            #expect(failed["read_succeeded"] as? Int == 1)
            #expect(failed["refreshed"] as? Bool == false)
            #expect(AccessoryFreshnessContract.violation(in: failed, allowStale: false)?
                .contains("1 of 2 characteristic reads succeeded") == true)
        }
    }

    @Test("Vendor-only rows cannot be attested fresh; explicit no-refresh is unchanged")
    func vendorOnly() {
        var report = AccessoryReadReport()
        report.skipUnmapped(characteristicID: first)
        let result = report.applyingFreshness(to: [:])
        #expect(result["refreshed"] as? Bool == false)
        #expect(result["read_attempted"] as? Int == 0)
        #expect(result["read_skipped_unmapped"] as? Int == 1)
        #expect(AccessoryFreshnessContract.violation(in: result, allowStale: false) != nil)

        let data = ["services": [["characteristics": [["name": "vendor", "value": "cached"]]]]]
        let stale = AccessoryReadReport.applyingNoRefresh(to: data)
        #expect(stale["read_skipped_unmapped"] == nil)
        #expect(AccessoryFreshnessContract.violation(in: stale, allowStale: false) != nil)
        #expect(AccessoryFreshnessContract.violation(in: stale, allowStale: true) == nil)
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
