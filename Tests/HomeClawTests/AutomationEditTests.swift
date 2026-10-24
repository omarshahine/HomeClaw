import HomeKit
import XCTest
@testable import HomeClaw

/// `automations edit`: the predicate helpers it relies on to keep the conjunct kinds
/// an edit doesn't replace, and the demo-mode contract the manager mirrors.
/// HomeKit triggers have no public initializers, so the live write path is not
/// covered here (see docs/TEST_PLAN.md).
@MainActor
final class AutomationEditTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        DemoFixtures.resetState()
    }

    override func tearDown() async throws {
        DemoFixtures.resetState()
        try await super.tearDown()
    }

    // MARK: - Conjunct helpers

    private func weekdayPredicate(_ weekday: Int) -> NSPredicate {
        var dc = DateComponents()
        dc.weekday = weekday
        return NSComparisonPredicate(
            leftExpression: NSExpression(forKeyPath: "currentDate"),
            rightExpression: NSExpression(forConstantValue: dc),
            modifier: .direct, type: .equalTo, options: [])
    }

    func testConjunctKindClassifiesTimeWeekdayAndUnknown() throws {
        let sunset = try XCTUnwrap(TimeCondition.parse("sunset-30", relation: .after)?.predicate())
        let clock = try XCTUnwrap(TimeCondition.parse("22:00", relation: .before)?.predicate())
        XCTAssertEqual(AccessoryModel.conjunctKind(sunset), "time")
        XCTAssertEqual(AccessoryModel.conjunctKind(clock), "time")
        XCTAssertEqual(AccessoryModel.conjunctKind(weekdayPredicate(2)), "weekdays")
        XCTAssertEqual(AccessoryModel.conjunctKind(NSPredicate(value: true)), "unknown")
    }

    /// The sun predicates HomeClaw writes use a key-path event (`sunset <= now()`), which
    /// the string-constant branch of the decoder missed; they decoded as `unknown`.
    func testSunPredicatesDecodeWithRelation() throws {
        for (raw, relation, expected) in [
            ("sunset", TimeCondition.Relation.after, ("after", "sunset")),
            ("sunset-30", .after, ("after", "sunset")),
            ("sunrise", .before, ("before", "sunrise")),
            ("sunrise+15", .before, ("before", "sunrise")),
        ] {
            let predicate = try XCTUnwrap(TimeCondition.parse(raw, relation: relation)?.predicate())
            let decoded = try XCTUnwrap(AccessoryModel.extractConditions(predicate, in: nil).first, raw)
            XCTAssertEqual(decoded["type"] as? String, "time", raw)
            XCTAssertEqual(decoded["relation"] as? String, expected.0, raw)
            XCTAssertEqual(decoded["event"] as? String, expected.1, raw)
        }
    }

    func testTopLevelConjunctsFlattensNestedAnds() throws {
        let after = try XCTUnwrap(TimeCondition.parse("sunset", relation: .after)?.predicate())
        let before = try XCTUnwrap(TimeCondition.parse("23:00", relation: .before)?.predicate())
        let nested = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSCompoundPredicate(andPredicateWithSubpredicates: [after, before]),
            weekdayPredicate(7),
        ])
        let conjuncts = AccessoryModel.topLevelConjuncts(nested)
        XCTAssertEqual(conjuncts.map(AccessoryModel.conjunctKind), ["time", "time", "weekdays"])
        XCTAssertEqual(AccessoryModel.topLevelConjuncts(nil).count, 0)
        // A single non-compound predicate is its own only conjunct.
        XCTAssertEqual(AccessoryModel.topLevelConjuncts(after).count, 1)
    }

    func testWeekdaySetSortsDeduplicatesAndDropsInvalid() {
        func components(_ weekday: Int?) -> DateComponents {
            var dc = DateComponents()
            dc.weekday = weekday
            return dc
        }
        XCTAssertEqual(HomeKitManager.weekdaySet([components(7), components(2), components(2), components(9), components(nil)]), [2, 7])
        XCTAssertEqual(HomeKitManager.weekdaySet(nil), [])
    }

    func testBareEventSummaryStripsSuffixes() {
        XCTAssertEqual(HomeKitManager.bareEventSummary("at sunset-30m (off after 5m) (+2 conditions)"), "at sunset-30m")
        XCTAssertEqual(HomeKitManager.bareEventSummary("Hall Sensor motion_detected = true (+1 condition)"), "Hall Sensor motion_detected = true")
        XCTAssertEqual(HomeKitManager.bareEventSummary("at 03:17"), "at 03:17")
    }

    // MARK: - Demo contract

    private func makeButtonAutomation() throws -> String {
        let created = try XCTUnwrap(DemoFixtures.createAutomation(
            name: "Hall Button", accessoryID: DemoFixtures.accessories[0].id, triggerType: "button",
            pressType: "single", serviceIndex: nil, characteristic: nil, triggerValue: nil,
            sceneName: DemoFixtures.scenes[0].name, actions: nil, conditions: [], timeAfter: [], timeBefore: [],
            weekdays: [], weekdaysAutoFilled: false, durationSeconds: nil, dryRun: false))
        return try XCTUnwrap(created["id"] as? String)
    }

    func testDemoEditKeepsIDAndChangesOnlyGivenFields() throws {
        let id = try makeButtonAutomation()
        let result = try XCTUnwrap(DemoFixtures.editAutomation(
            id: id, newName: "Hall at dusk", time: "sunset", weekdays: nil, conditions: nil, timeEchoes: nil,
            durationSeconds: 300, clearDuration: false, dryRun: false))

        XCTAssertEqual(result["id"] as? String, id)
        XCTAssertEqual(Set(result["changes"] as? [String] ?? []), ["events", "weekdays", "duration", "name"])
        let planned = try XCTUnwrap(result["planned"] as? [String: Any])
        XCTAssertEqual(planned["weekdays"] as? [Int], [1, 2, 3, 4, 5, 6, 7], "a time trigger without --days gets every day auto-filled")
        XCTAssertEqual(planned["weekdays_auto_filled"] as? Bool, true)
        XCTAssertEqual(result["verified"] as? Bool, true)

        let stored = try XCTUnwrap(DemoFixtures.automations.first { $0.id == id })
        XCTAssertEqual(stored.name, "Hall at dusk")
        XCTAssertEqual(stored.triggerType, "time")
        XCTAssertEqual(stored.time, "sunset")
        XCTAssertNil(stored.accessoryName)
        XCTAssertEqual(stored.durationSeconds, 300)
        XCTAssertEqual(stored.sceneName, DemoFixtures.scenes[0].name, "edit leaves the attached scene alone")
    }

    func testDemoDryRunDoesNotMutate() throws {
        let id = try makeButtonAutomation()
        let result = try XCTUnwrap(DemoFixtures.editAutomation(
            id: id, newName: "Renamed", time: nil, weekdays: [2, 3], conditions: nil, timeEchoes: nil,
            durationSeconds: nil, clearDuration: false, dryRun: true))
        XCTAssertEqual(result["dry_run"] as? Bool, true)
        XCTAssertNil(result["automation"])
        XCTAssertEqual(DemoFixtures.automations.first { $0.id == id }?.name, "Hall Button")
        XCTAssertEqual(DemoFixtures.automations.first { $0.id == id }?.weekdays, [])
    }

    func testDemoClearsWithEmptyValues() throws {
        let id = try makeButtonAutomation()
        _ = try DemoFixtures.editAutomation(
            id: id, newName: nil, time: nil, weekdays: [2], conditions: [["accessory": "Front Door", "property": "contact_state", "value": "0"]],
            timeEchoes: (after: ["sunset"], before: []), durationSeconds: 60, clearDuration: false, dryRun: false)
        let result = try XCTUnwrap(DemoFixtures.editAutomation(
            id: id, newName: nil, time: nil, weekdays: [], conditions: [], timeEchoes: (after: [], before: []),
            durationSeconds: nil, clearDuration: true, dryRun: false))

        let stored = try XCTUnwrap(DemoFixtures.automations.first { $0.id == id })
        XCTAssertTrue(stored.conditions.isEmpty)
        XCTAssertTrue(stored.timeAfter.isEmpty)
        XCTAssertEqual(stored.weekdays, [], "a button trigger without a time window is not auto-filled")
        XCTAssertNil(stored.durationSeconds)
        XCTAssertEqual(Set(result["changes"] as? [String] ?? []), ["predicate", "weekdays", "duration"])
    }

    func testDemoUnchangedAndUnknown() throws {
        let id = try makeButtonAutomation()
        let same = try XCTUnwrap(DemoFixtures.editAutomation(
            id: id, newName: "Hall Button", time: nil, weekdays: nil, conditions: nil, timeEchoes: nil,
            durationSeconds: nil, clearDuration: false, dryRun: false))
        XCTAssertEqual(same["unchanged"] as? Bool, true)
        XCTAssertNil(same["automation"])

        XCTAssertNil(try DemoFixtures.editAutomation(
            id: "no such automation", newName: "x", time: nil, weekdays: nil, conditions: nil, timeEchoes: nil,
            durationSeconds: nil, clearDuration: false, dryRun: false))
    }
}
