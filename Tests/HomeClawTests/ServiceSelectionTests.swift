import HomeKit
import XCTest
@testable import HomeClaw

/// Service selection for service-level writes (rename one gang, Display As).
/// `HMService` has no public initializer, so these drive the plain-value helpers
/// `selectService` is built on.
final class ServiceSelectionTests: XCTestCase {
    private struct Service: Equatable {
        let name: String
        let type: String
        let uuid: String
        let index: Int?
    }

    private let gang1 = Service(name: "Downlight 1", type: HMServiceTypeSwitch, uuid: "5F2A0000-0000-0000-0000-000000000001", index: 1)
    private let gang2 = Service(name: "Switch 2", type: HMServiceTypeSwitch, uuid: "B3E00000-0000-0000-0000-000000000002", index: 2)

    private func pick(
        _ candidates: [Service],
        type: String? = nil, name: String? = nil, id: String? = nil, index: Int? = nil
    ) -> HomeKitManager.ServicePick<Service> {
        HomeKitManager.pickService(from: candidates, where: {
            HomeKitManager.serviceMatches(
                serviceType: $0.type, serviceName: $0.name, serviceUUID: $0.uuid, labelIndex: $0.index,
                type: type, name: name, id: id, index: index
            )
        })
    }

    func testLoneCandidateNeedsNoSelector() {
        guard case .found(let s) = pick([gang1]) else { return XCTFail("expected found") }
        XCTAssertEqual(s, gang1)
    }

    func testTwoGangsWithoutSelectorAreAmbiguousNotFirst() {
        guard case .ambiguous(let matches) = pick([gang1, gang2]) else { return XCTFail("expected ambiguous") }
        XCTAssertEqual(matches, [gang1, gang2])
    }

    func testServiceTypeAloneCannotPickAGang() {
        guard case .ambiguous = pick([gang1, gang2], type: HMServiceTypeSwitch) else {
            return XCTFail("expected ambiguous")
        }
    }

    func testEachSelectorPicksOneGang() {
        for result in [
            pick([gang1, gang2], name: "switch 2"),
            pick([gang1, gang2], name: gang2.uuid.lowercased()),
            pick([gang1, gang2], id: gang2.uuid.lowercased()),
            pick([gang1, gang2], index: 2),
        ] {
            guard case .found(let s) = result else { return XCTFail("expected found") }
            XCTAssertEqual(s, gang2)
        }
    }

    func testSelectorsCombineWithAnd() {
        guard case .noMatch = pick([gang1, gang2], name: "Switch 2", index: 1) else {
            return XCTFail("expected noMatch")
        }
    }

    func testNoCandidatesIsDistinctFromNoMatch() {
        guard case .noCandidates = pick([], name: "Switch 2") else { return XCTFail("expected noCandidates") }
        guard case .noMatch = pick([gang1], name: "Switch 2") else { return XCTFail("expected noMatch") }
    }

    func testIndexMatchesOnlyServicesThatReportOne() {
        let unlabeled = Service(name: "Outlet", type: HMServiceTypeOutlet, uuid: "C0000000-0000-0000-0000-000000000003", index: nil)
        guard case .noMatch = pick([unlabeled], index: 1) else { return XCTFail("expected noMatch") }
    }

    func testAccessoryInformationIsNeverRenamable() {
        XCTAssertFalse(HomeKitManager.isRenamableService(type: HMServiceTypeAccessoryInformation))
        XCTAssertTrue(HomeKitManager.isRenamableService(type: HMServiceTypeSwitch))
        XCTAssertTrue(HomeKitManager.isRenamableService(type: HMServiceTypeLightbulb))
    }
}
