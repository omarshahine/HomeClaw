import Foundation
import Testing
@testable import HomeClawFreshness

@Suite("Accessory freshness contract")
struct AccessoryFreshnessContractTests {
    private func payload(refreshed: Bool, attempted: Int, succeeded: Int, reachable: Bool = true) -> [String: Any] {
        let read: [String: Any] = ["succeeded": true, "observed_at": "2026-09-21T10:00:00.123Z"]
        return ["reachable": reachable, "refreshed": refreshed, "read_attempted": attempted, "read_succeeded": succeeded,
                "services": [["characteristics": Array(repeating: ["read": read], count: attempted)]]]
    }

    @Test("A fully refreshed payload passes")
    func fresh() {
        #expect(AccessoryFreshnessContract.violation(in: payload(refreshed: true, attempted: 2, succeeded: 2), allowStale: false) == nil)
    }

    @Test("A partial refresh names the counts and the no_refresh escape hatch")
    func partial() {
        let message = AccessoryFreshnessContract.violation(in: payload(refreshed: false, attempted: 2, succeeded: 1), allowStale: false)
        #expect(message == "HomeClaw freshness contract violation: live refresh failed (1 of 2 characteristic reads succeeded); values may be last-known. Pass no_refresh: true to read last-known values")
    }

    @Test("An unreachable accessory says so")
    func unreachable() {
        let message = AccessoryFreshnessContract.violation(in: payload(refreshed: false, attempted: 1, succeeded: 0, reachable: false), allowStale: false)
        #expect(message?.contains("accessory is not reachable") == true)
    }

    @Test("no_refresh accepts only the explicit last-known shape")
    func noRefresh() {
        #expect(AccessoryFreshnessContract.violation(in: payload(refreshed: false, attempted: 0, succeeded: 0), allowStale: true) == nil)
        #expect(AccessoryFreshnessContract.violation(in: payload(refreshed: true, attempted: 1, succeeded: 1), allowStale: true) != nil)
    }
}
