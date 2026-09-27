import XCTest
@testable import HomeClaw

/// Duplicate accessory names (common after a re-pair) must never resolve to
/// whichever accessory HomeKit enumerates first: every write path resolves
/// names through `pickVisibleMatch`.
final class AccessoryNameResolutionTests: XCTestCase {
    private struct Candidate: Equatable {
        let id: String
        let visible: Bool
    }

    private func pick(_ matches: [Candidate]) -> HomeKitManager.IdentifierMatch<Candidate> {
        HomeKitManager.pickVisibleMatch(matches, isVisible: { $0.visible })
    }

    func testNoMatchesIsNotFound() {
        guard case .notFound = pick([]) else { return XCTFail("expected notFound") }
    }

    func testSingleVisibleMatchResolves() {
        guard case .found(let c) = pick([Candidate(id: "A", visible: true)]) else {
            return XCTFail("expected found")
        }
        XCTAssertEqual(c.id, "A")
    }

    func testSeveralVisibleMatchesAreAmbiguous() {
        let matches = [Candidate(id: "A", visible: true), Candidate(id: "B", visible: true)]
        guard case .ambiguous(let candidates) = pick(matches) else { return XCTFail("expected ambiguous") }
        XCTAssertEqual(candidates.map(\.id), ["A", "B"])
    }

    func testHiddenDuplicateNeitherLeaksNorBlocksTheVisibleOne() {
        let matches = [Candidate(id: "hidden", visible: false), Candidate(id: "shown", visible: true)]
        guard case .found(let c) = pick(matches) else { return XCTFail("expected found") }
        XCTAssertEqual(c.id, "shown")
    }

    func testAmbiguityListsOnlyVisibleCandidates() {
        let matches = [
            Candidate(id: "A", visible: true), Candidate(id: "hidden", visible: false),
            Candidate(id: "B", visible: true),
        ]
        guard case .ambiguous(let candidates) = pick(matches) else { return XCTFail("expected ambiguous") }
        XCTAssertFalse(candidates.contains { !$0.visible })
    }

    func testOnlyHiddenMatchIsReturnedForTheCallerToReject() {
        guard case .found(let c) = pick([Candidate(id: "hidden", visible: false)]) else {
            return XCTFail("expected found")
        }
        XCTAssertFalse(c.visible)
    }

    func testAmbiguityErrorNamesTheQueryAndPointsToUUIDs() {
        let message = HomeKitManager.ControlError.ambiguousAccessory("Lamp", "  - Lamp — Den (A)").localizedDescription
        XCTAssertTrue(message.contains("'Lamp' matches multiple accessories"))
        XCTAssertTrue(message.contains("accessory UUID"))
    }
}
