import Foundation
#if !WRITE_VERIFICATION_STANDALONE
import XCTest
@testable import HomeClaw
#endif

@MainActor
private func verifyReadback() async throws {
    struct Failure: Error { let detail: String }
    func expect(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
        guard condition() else { throw Failure(detail: detail) }
    }

    func poll(bridged: Bool = true, read: (Duration, TimeInterval) -> (Duration, AccessoryWriteVerification.Observation))
        async -> (AccessoryWriteVerification.Outcome, [Duration], [TimeInterval]) {
        var time: Duration = .zero
        var calls: [Duration] = []
        var timeouts: [TimeInterval] = []
        let outcome = await AccessoryWriteVerification.confirm(
            bridged: bridged, elapsed: { time }, sleep: { time += $0 },
            read: { timeout in
                calls.append(time)
                timeouts.append(timeout)
                let (latency, observation) = read(time, timeout)
                time += latency
                return observation
            }
        )
        return (outcome, calls, timeouts)
    }

    let immediate = await poll { _, _ in (.zero, .matches("true")) }
    try expect(immediate.0 == .confirmed(value: "true") && immediate.1 == [.zero], "Immediate confirmation should stop at one read")

    for delay in [1, 2, 3, 4] {
        let result = await poll { time, _ in (.zero, time >= .seconds(delay) ? .matches("true") : .differs("true")) }
        try expect(result.0 == .confirmed(value: "true") && result.1.last == .seconds(delay), "Delayed bridge did not confirm at \(delay)s")
    }

    let direct = await poll(bridged: false) { _, _ in (.zero, .differs("true")) }
    try expect(direct.1 == [.zero, .milliseconds(250), .milliseconds(500)], "Direct accessory must retain schedule")

    let noMatch = await poll { _, _ in (.zero, .differs("true")) }
    try expect(noMatch.0 == .unconfirmed(lastRead: "true") && noMatch.1.count == 10, "Mismatch must stay unconfirmed")

    // Failed reads must not attest a matching notification/cache value. The
    // adapter reports unavailable, not the cached value, on a failed read.
    func matchingStaleCache() -> String? {
        // A failed live read left a matching cached model value.
        "true"
    }
    let staleCache = AccessoryWriteVerification.observe(
        succeeded: false, value: matchingStaleCache(),
        matches: { $0 == "true" }, format: { $0 }
    )
    try expect(staleCache == .unavailable, "Do not treat a matching stale cache as live")
    let noFreshValue = await poll { _, _ in (.zero, .unavailable) }
    try expect(noFreshValue.0 == .unconfirmed(lastRead: nil), "Failed reads cannot confirm")

    let mismatchThenErrors = await poll { time, _ in (.zero, time == .zero ? .differs("false") : .unavailable) }
    try expect(mismatchThenErrors.0 == .unconfirmed(lastRead: "false"), "Do not replace fresh mismatch with failed-read cache")

    let hung = await poll { _, timeout in (.nanoseconds(Int64(timeout * 1e9)), .unavailable) }
    try expect(hung.1 == [.zero, .seconds(2), .seconds(4)] && hung.2 == [1.5, 1.5, 1.0], "Per-read deadline must be clamped")
    let lateMatch = await poll { _, _ in (.seconds(6), .matches("true")) }
    try expect(lateMatch.0 == .unconfirmed(lastRead: nil), "Do not accept a read result after the deadline")

    // A stale unrelated channel still appears in the service summary, but
    // only the exact target's captured value receives a "verified" marker.
    let serviceSummaries = [
        ["name": "target", "state_source": "last_known", "power": "false"],
        ["name": "untargeted", "state_source": "last_known", "power": "false"],
    ]
    var summary: [String: Any] = ["services": serviceSummaries, "state": ["power": "false"]]
    summary.merge(AccessoryWriteVerification.successFields(
        confirmedValue: "true", verificationRequested: true, lastKnownValue: "false"
    )) { _, current in current }
    try expect(summary["value"] as? String == "true" && summary["verified"] as? Bool == true,
               "Do not replace the verified target with a later cached value")
    try expect(summary["state_source"] as? String == "last_known"
               && summary["services"] as? [[String: String]] == serviceSummaries,
               "Do not mark unrelated state as live or overwrite shared multi-channel values")

    let skipped = AccessoryWriteVerification.successFields(
        confirmedValue: nil, verificationRequested: false, lastKnownValue: "false"
    )
    try expect(skipped["value"] as? String == "false" && skipped["verified"] == nil
               && skipped["verification_skipped"] as? String == "disabled",
               "Explicit opt-out still returns the last-known value without verification")
    let writeOnly = AccessoryWriteVerification.successFields(
        confirmedValue: nil, verificationRequested: true, lastKnownValue: nil
    )
    try expect(writeOnly["value"] == nil && writeOnly["verified"] == nil
               && writeOnly["verification_skipped"] as? String == "not_readable",
               "Write-only controls must not claim verification")

    let rejected = AccessoryWriteFailure.failed("Not authorized")
    let unconfirmed = AccessoryWriteFailure.unconfirmed("no fresh value was returned")
    try expect(rejected.code == "write_failed" && unconfirmed.code == "write_unconfirmed", "Keep distinct wire codes")
    try expect(unconfirmed.localizedDescription.contains("fresh read before trying"), "Do not suggest automatic rewrite")
}

#if WRITE_VERIFICATION_STANDALONE
@main struct AccessoryWriteTestRunner {
    @MainActor static func main() async throws {
        try await verifyReadback()
        print("Passed bridge write verification cases")
    }
}
#else
@MainActor final class AccessoryWriteVerificationTests: XCTestCase {
    func testReadbackTimingAndOutcomes() async throws { try await verifyReadback() }
}
#endif
