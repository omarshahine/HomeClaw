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

    let immediate = await poll { _, _ in (.zero, .matches) }
    try expect(immediate.0 == .confirmed && immediate.1 == [.zero], "Immediate confirmation should stop at one read")

    for delay in [1, 2, 3, 4] {
        let result = await poll { time, _ in (.zero, time >= .seconds(delay) ? .matches : .differs("true")) }
        try expect(result.0 == .confirmed && result.1.last == .seconds(delay), "Delayed bridge did not confirm at \(delay)s")
    }

    let direct = await poll(bridged: false) { _, _ in (.zero, .differs("true")) }
    try expect(direct.1 == [.zero, .milliseconds(250), .milliseconds(500)], "Direct accessory must retain schedule")

    let noMatch = await poll { _, _ in (.zero, .differs("true")) }
    try expect(noMatch.0 == .unconfirmed(lastRead: "true") && noMatch.1.count == 10, "Mismatch must stay unconfirmed")

    // Failed reads must not attest a matching notification/cache value. The
    // adapter reports unavailable, not the cached value, on a failed read.
    let noFreshValue = await poll { _, _ in (.zero, .unavailable) }
    try expect(noFreshValue.0 == .unconfirmed(lastRead: nil), "Failed reads cannot confirm")

    let mismatchThenErrors = await poll { time, _ in (.zero, time == .zero ? .differs("false") : .unavailable) }
    try expect(mismatchThenErrors.0 == .unconfirmed(lastRead: "false"), "Do not replace fresh mismatch with failed-read cache")

    let hung = await poll { _, timeout in (.nanoseconds(Int64(timeout * 1e9)), .unavailable) }
    try expect(hung.1 == [.zero, .seconds(2), .seconds(4)] && hung.2 == [1.5, 1.5, 1.0], "Per-read deadline must be clamped")
    let lateMatch = await poll { _, _ in (.seconds(6), .matches) }
    try expect(lateMatch.0 == .unconfirmed(lastRead: nil), "Do not accept a read result after the deadline")

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
