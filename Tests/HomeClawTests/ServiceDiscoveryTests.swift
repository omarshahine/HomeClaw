import XCTest
@testable import HomeClaw

final class ServiceDiscoveryTests: XCTestCase {
    private func channel(_ id: String, _ name: String, _ power: String? = nil,
                         category: String? = "switch", displayAs: String? = "light",
                         index: Int? = nil, controllable: Bool = true) -> ServiceDiscovery.Service {
        .init(id: id, name: name, category: category, displayAs: displayAs, index: index,
              controllable: controllable, state: power.map { ["power": $0] } ?? [:])
    }
    private var gangs: [ServiceDiscovery.Service] {
        [channel("dining-id", "餐厅灯", "true", index: 1), channel("kitchen-id", "厨房灯", "false", index: 2)]
    }

    func testChineseChannelNamesAndOppositeStatesRemainDistinct() throws {
        let rows = ServiceDiscovery.summaries(gangs)
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["dining-id", "kitchen-id"])
        XCTAssertEqual(rows.compactMap { $0["name"] as? String }, ["餐厅灯", "厨房灯"])
        XCTAssertEqual(rows.compactMap { $0["index"] as? Int }, [1, 2])
        XCTAssertEqual(rows.compactMap { ($0["state"] as? [String: String])?["power"] }, ["true", "false"])
        XCTAssertTrue(rows.allSatisfy { $0["display_as"] as? String == "light" })
        XCTAssertTrue(rows.allSatisfy { $0["state_source"] as? String == "last_known" })
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: rows))
    }

    func testAliasesFindNamesOutsideTheAccessoryRoom() {
        let aliases = ServiceDiscovery.aliases(gangs)
        XCTAssertTrue(aliases.contains { $0.contains("厨房灯") })
        XCTAssertTrue(aliases.contains { $0.contains("餐厅灯") })
        XCTAssertEqual(aliases, ["餐厅灯", "厨房灯"])
    }

    func testDisplayAsAndRawServiceCategoryMatchWithoutChangingAccessoryCategory() {
        for category in ["lightbulb", "LIGHTBULB", "switch"] {
            XCTAssertTrue(ServiceDiscovery.matchesCategory(category, accessoryCategory: "switch", services: gangs))
        }
        XCTAssertFalse(ServiceDiscovery.matchesCategory("fan", accessoryCategory: "switch", services: gangs))
        let fan = [channel("fan-id", "Fan", category: "outlet", displayAs: "fan")]
        XCTAssertTrue(ServiceDiscovery.matchesCategory("fan", accessoryCategory: "other", services: fan))
        XCTAssertTrue(ServiceDiscovery.matchesCategory("outlet", accessoryCategory: "other", services: fan))
    }

    func testSupportingAndUnknownServicesDoNotCreateExtraChannelsOrAliases() {
        let supporting = [channel("battery", "Hidden battery", category: nil, displayAs: nil, controllable: false),
                          channel("ota", "Private updater", category: nil, controllable: true),
                          channel("sensor", "Motion", category: "sensor", controllable: false)]
        XCTAssertTrue(ServiceDiscovery.summaries([gangs[0]] + supporting).isEmpty)
        XCTAssertEqual(ServiceDiscovery.aliases(gangs + supporting), ["餐厅灯", "厨房灯"])
        XCTAssertFalse(ServiceDiscovery.matchesCategory("sensor", accessoryCategory: "switch", services: gangs + supporting))
    }

    func testSingleChannelAndMissingValuesKeepCompactShape() {
        XCTAssertTrue(ServiceDiscovery.summaries([]).isEmpty)
        XCTAssertTrue(ServiceDiscovery.summaries([gangs[0]]).isEmpty)
        let rows = ServiceDiscovery.summaries([channel("one", "One"), channel("two", "Two", "false")])
        XCTAssertNil(rows[0]["state"])
        XCTAssertNil(rows[0]["state_source"])
        XCTAssertNil(rows[0]["index"])
        XCTAssertEqual((rows[1]["state"] as? [String: String])?["power"], "false")
    }

    func testDuplicateAndBlankNamesRetainDistinctSelectableIDs() {
        let services = [channel("a", " Kitchen Light "), channel("b", "KITCHEN LIGHT"), channel("c", " \n")]
        XCTAssertEqual(ServiceDiscovery.aliases(services), ["kitchen light"])
        XCTAssertEqual(ServiceDiscovery.summaries(services).compactMap { $0["id"] as? String }, ["a", "b", "c"])
    }

    func testExistingAccessoryCategoryMatchIsPreserved() {
        XCTAssertTrue(ServiceDiscovery.matchesCategory("lightbulb", accessoryCategory: "lightbulb", services: []))
        XCTAssertFalse(ServiceDiscovery.matchesCategory("switch", accessoryCategory: "lightbulb", services: []))
    }
}
