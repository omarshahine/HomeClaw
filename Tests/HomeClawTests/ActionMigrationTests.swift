import HomeKit
import XCTest
@testable import HomeClaw

/// Planning for `automations migrate-actions` (#120). HomeKit objects have no
/// public initializers, so these drive the plain-value planner the manager
/// snapshots the home into.
final class ActionMigrationTests: XCTestCase {
    typealias M = ActionMigration

    // MARK: - Fixtures

    private let power = HMCharacteristicTypePowerState
    private let brightness = HMCharacteristicTypeBrightness
    private let hue = HMCharacteristicTypeHue
    private let colorTemp = HMCharacteristicTypeColorTemperature
    private let lightbulb = HMServiceTypeLightbulb
    private let switchType = HMServiceTypeSwitch
    private let outlet = HMServiceTypeOutlet

    private let oldID = "0LD00000-0000-0000-0000-000000000001"

    private func char(_ accessory: String, _ service: String, _ type: String, writable: Bool = true) -> M.Characteristic {
        M.Characteristic(id: "\(accessory).\(service).\(type)", type: type, name: CharacteristicMapper.name(for: type), writable: writable)
    }

    private func service(_ accessory: String, _ id: String, type: String, _ chars: [String], readOnly: Set<String> = []) -> M.Service {
        M.Service(id: "\(accessory).\(id)", name: "\(accessory) \(id)", type: type,
                  characteristics: chars.map { char(accessory, id, $0, writable: !readOnly.contains($0)) })
    }

    private func accessory(_ id: String, _ services: [M.Service]) -> M.Accessory {
        M.Accessory(id: id, name: "Acc \(id)", room: "Kitchen", services: services)
    }

    private func row(_ n: Int, accessory: String? = nil, service: String = "s1", serviceType: String? = nil,
                     _ type: String, _ value: M.Value) -> M.ActionRow {
        let acc = accessory ?? oldID
        return M.ActionRow(
            actionID: "action-\(n)", accessoryID: acc, accessoryName: acc == oldID ? "Old Lamp" : "Acc \(acc)",
            room: "Kitchen", serviceID: "\(acc).\(service)", serviceName: "\(acc) \(service)",
            serviceType: serviceType ?? lightbulb, characteristicID: "\(acc).\(service).\(type)",
            characteristicType: type, characteristicName: CharacteristicMapper.name(for: type), value: value)
    }

    private var old: M.OldAccessory { M.OldAccessory(id: oldID, name: "Old Lamp", room: "Kitchen", present: true) }

    private func set(_ rows: [M.ActionRow], visible: Bool = true, id: String = "SET-1",
                     usedBy: [M.TriggerRef] = [M.TriggerRef(id: "AUTO-1", name: "Evening")]) -> M.ActionSetSnapshot {
        M.ActionSetSnapshot(id: id, name: visible ? "Evening Scene" : "", visible: visible, rows: rows,
                            nonWriteActionCount: 0, usedBy: usedBy)
    }

    private func automation(_ sets: [M.ActionSetSnapshot], id: String = "AUTO-1", name: String = "Evening") -> M.AutomationSnapshot {
        M.AutomationSnapshot(id: id, name: name, enabled: true, triggerType: "calendar", triggerSummary: "at 18:00",
                             triggerUsesOldAccessory: false, actionSets: sets)
    }

    private func plan(_ s: M.ActionSetSnapshot, _ replacements: [M.Accessory]) -> M.SetPlan? {
        M.plan(set: s, automation: automation([s]), old: old, replacements: replacements)
    }

    private lazy var colorBulb = accessory("NEW-BULB", [service("NEW-BULB", "light", type: lightbulb, [power, brightness, hue, colorTemp])])
    private lazy var plainSwitch = accessory("NEW-SW", [service("NEW-SW", "sw", type: switchType, [power])])

    // MARK: - Classification and status

    func testVisibleSceneWithFullMatchIsSupported() throws {
        let p = try XCTUnwrap(plan(set([row(1, power, .bool(true)), row(2, brightness, .int(50))]), [colorBulb]))
        XCTAssertEqual(p.classification, .visibleScene)
        XCTAssertEqual(p.status, .supported)
        XCTAssertNil(p.reason)
        XCTAssertEqual(p.removals.map(\.actionID), ["action-1", "action-2"])
        XCTAssertEqual(p.additions.map(\.characteristicID), ["NEW-BULB.light.\(power)", "NEW-BULB.light.\(brightness)"])
        XCTAssertEqual(p.additions.map(\.value), [.bool(true), .int(50)])
        XCTAssertTrue(p.manualSteps.isEmpty)
        XCTAssertEqual(p.rollback.count, 2)
    }

    func testHiddenSetIsAlwaysUnsupportedEvenWhenFullyMappable() throws {
        let p = try XCTUnwrap(plan(set([row(1, power, .bool(true))], visible: false), [colorBulb]))
        XCTAssertEqual(p.classification, .hidden)
        XCTAssertEqual(p.status, .unsupported)
        XCTAssertEqual(p.reason, "hidden_action_set_requires_private_spi")
        XCTAssertEqual(p.additions.count, 1, "the mapping is still computed so manual steps can name it")
        XCTAssertFalse(M.setsToApply([M.AutomationPlan(automation: automation([]), sets: [p])]).contains(p),
                       "unsupported sets never receive writes")
    }

    func testHiddenSetStaysUnsupportedWhenAlsoBlocked() throws {
        let p = try XCTUnwrap(plan(set([row(1, hue, .int(200))], visible: false), [plainSwitch]))
        XCTAssertEqual(p.status, .unsupported)
        XCTAssertTrue(p.issues.contains { $0.kind == .unmapped && $0.blocking })
    }

    func testSetWithoutOldAccessoryActionsIsNotPlanned() {
        XCTAssertNil(plan(set([row(1, accessory: "OTHER", power, .bool(true))]), [colorBulb]))
        let plans = M.plan(automations: [automation([set([row(1, accessory: "OTHER", power, .bool(true))])])],
                           old: old, replacements: [colorBulb])
        XCTAssertTrue(plans.isEmpty)
    }

    func testOldAccessoryUUIDMatchesCaseInsensitively() throws {
        let lower = M.OldAccessory(id: oldID.lowercased(), name: nil, room: nil, present: false)
        let s = set([row(1, power, .bool(true))])
        let p = try XCTUnwrap(M.plan(set: s, automation: automation([s]), old: lower, replacements: [colorBulb]))
        XCTAssertEqual(p.removals.count, 1)
    }

    // MARK: - Characteristic mapping

    func testAllLightCharacteristicsMap() throws {
        let rows = [row(1, power, .bool(true)), row(2, brightness, .int(40)), row(3, hue, .int(30)), row(4, colorTemp, .int(312))]
        let p = try XCTUnwrap(plan(set(rows), [colorBulb]))
        XCTAssertEqual(p.status, .supported)
        XCTAssertEqual(Set(p.additions.map(\.characteristicName)), ["power", "brightness", "hue", "color_temperature"])
    }

    func testMissingOnOneReplacementButPresentOnAnotherIsReportedNotBlocking() throws {
        let p = try XCTUnwrap(plan(set([row(1, power, .bool(true)), row(2, brightness, .int(50))]), [colorBulb, plainSwitch]))
        XCTAssertEqual(p.status, .supported)
        XCTAssertEqual(p.additions.filter { $0.accessoryID == "NEW-SW" }.map(\.characteristicName), ["power"])
        let missing = try XCTUnwrap(p.issues.first { $0.kind == .missingCharacteristic })
        XCTAssertFalse(missing.blocking)
        XCTAssertEqual(missing.newAccessoryID, "NEW-SW")
        XCTAssertEqual(missing.characteristicName, "brightness")
    }

    func testCharacteristicNoReplacementCanTakeBlocks() throws {
        let p = try XCTUnwrap(plan(set([row(1, power, .bool(true)), row(2, brightness, .int(50))]), [plainSwitch]))
        XCTAssertEqual(p.status, .blocked)
        XCTAssertEqual(p.reason, "no_replacement_characteristic")
        XCTAssertTrue(p.issues.contains { $0.kind == .unmapped && $0.characteristicName == "brightness" && $0.blocking })
    }

    func testReadOnlyCharacteristicIsNotATarget() throws {
        let ro = accessory("RO", [service("RO", "light", type: lightbulb, [power, brightness], readOnly: [brightness])])
        let p = try XCTUnwrap(plan(set([row(1, brightness, .int(50))]), [ro]))
        XCTAssertEqual(p.status, .blocked)
        XCTAssertTrue(p.issues.contains { $0.kind == .notWritable })
        XCTAssertTrue(p.additions.isEmpty)
    }

    func testSeveralSameTypeServicesAreAmbiguousNotFirst() throws {
        let twoGang = accessory("GANG", [
            service("GANG", "g1", type: switchType, [power]),
            service("GANG", "g2", type: switchType, [power]),
        ])
        let p = try XCTUnwrap(plan(set([row(1, serviceType: switchType, power, .bool(true))]), [twoGang]))
        XCTAssertEqual(p.status, .blocked)
        let issue = try XCTUnwrap(p.issues.first { $0.kind == .ambiguousService })
        XCTAssertTrue(issue.blocking)
        XCTAssertEqual(issue.candidates.map(\.id), ["GANG.g1", "GANG.g2"])
        XCTAssertFalse(p.issues.contains { $0.kind == .unmapped }, "ambiguity is reported once, not also as unmapped")
    }

    func testAmbiguousCandidatesCarryServiceSelectors() throws {
        var g1 = service("GANG", "g1", type: switchType, [power]); g1.index = 1
        var g2 = service("GANG", "g2", type: switchType, [power]); g2.index = 2
        let p = try XCTUnwrap(plan(set([row(1, serviceType: switchType, power, .bool(true))]), [accessory("GANG", [g1, g2])]))
        let issue = try XCTUnwrap(p.issues.first { $0.kind == .ambiguousService })
        let json = M.json(issue)
        let candidates = try XCTUnwrap(json["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.map { $0["service_index"] as? Int }, [1, 2])
        XCTAssertEqual(candidates.map { $0["service_id"] as? String }, ["GANG.g1", "GANG.g2"])
        XCTAssertEqual(candidates.map { $0["service_name"] as? String }, ["GANG g1", "GANG g2"])
    }

    func testSameServiceTypeWinsOverOtherCarriers() throws {
        let combo = accessory("COMBO", [
            service("COMBO", "light", type: lightbulb, [power, brightness]),
            service("COMBO", "outlet", type: outlet, [power]),
        ])
        let p = try XCTUnwrap(plan(set([row(1, power, .bool(true))]), [combo]))
        XCTAssertEqual(p.status, .supported)
        XCTAssertEqual(p.additions.first?.serviceID, "COMBO.light")
        XCTAssertEqual(p.additions.first?.serviceTypeChanged, false)
    }

    func testSingleCarrierOfDifferentTypeIsAcceptedAndFlagged() throws {
        let p = try XCTUnwrap(plan(set([row(1, serviceType: outlet, power, .bool(true))]), [plainSwitch]))
        XCTAssertEqual(p.status, .supported)
        XCTAssertEqual(p.additions.first?.serviceTypeChanged, true)
    }

    func testSeveralCarriersOfOtherTypesAreAmbiguous() throws {
        let combo = accessory("COMBO", [
            service("COMBO", "sw", type: switchType, [power]),
            service("COMBO", "outlet", type: outlet, [power]),
        ])
        let p = try XCTUnwrap(plan(set([row(1, power, .bool(true))]), [combo]))
        XCTAssertEqual(p.status, .blocked)
        XCTAssertEqual(p.issues.first?.kind, .ambiguousService)
    }

    // MARK: - Conflicts

    func testTwoOldActionsOntoOneTargetWithDifferentValuesBlock() throws {
        let rows = [row(1, service: "g1", serviceType: switchType, power, .bool(true)),
                    row(2, service: "g2", serviceType: switchType, power, .bool(false))]
        let p = try XCTUnwrap(plan(set(rows), [plainSwitch]))
        XCTAssertEqual(p.status, .blocked)
        XCTAssertTrue(p.issues.contains { $0.kind == .conflictingSources })
        XCTAssertEqual(p.additions.count, 1)
    }

    func testTwoOldActionsOntoOneTargetWithSameValueMerge() throws {
        let rows = [row(1, service: "g1", serviceType: switchType, power, .bool(true)),
                    row(2, service: "g2", serviceType: switchType, power, .int(1))]
        let p = try XCTUnwrap(plan(set(rows), [plainSwitch]))
        XCTAssertEqual(p.status, .supported)
        XCTAssertEqual(p.additions.count, 1)
        XCTAssertEqual(p.expected.count, 1)
    }

    func testExistingActionWithSameValueIsAlreadyPresent() throws {
        let existing = row(9, accessory: "NEW-SW", service: "sw", serviceType: switchType, power, .bool(true))
        let p = try XCTUnwrap(plan(set([row(1, power, .bool(true)), existing]), [plainSwitch]))
        XCTAssertEqual(p.status, .supported)
        XCTAssertTrue(p.additions.isEmpty)
        XCTAssertTrue(p.issues.contains { $0.kind == .alreadyPresent && !$0.blocking })
        XCTAssertEqual(p.expected, [M.ExpectedAction(characteristicID: existing.characteristicID, value: .bool(true))])
    }

    func testExistingActionWithDifferentValueBlocks() throws {
        let existing = row(9, accessory: "NEW-SW", service: "sw", serviceType: switchType, power, .bool(false))
        let p = try XCTUnwrap(plan(set([row(1, power, .bool(true)), existing]), [plainSwitch]))
        XCTAssertEqual(p.status, .blocked)
        XCTAssertEqual(p.reason, "conflicts_with_existing_action")
    }

    // MARK: - Unrelated actions, sharing, expected contents

    func testUnrelatedActionsArePreservedInExpectedContents() throws {
        let other = row(5, accessory: "BLINDS", service: "wc", serviceType: HMServiceTypeWindowCovering,
                        HMCharacteristicTypeTargetPosition, .int(100))
        let p = try XCTUnwrap(plan(set([row(1, power, .bool(true)), other]), [colorBulb]))
        XCTAssertEqual(p.removals.map(\.actionID), ["action-1"])
        XCTAssertEqual(p.expected, [
            M.ExpectedAction(characteristicID: other.characteristicID, value: .int(100)),
            M.ExpectedAction(characteristicID: "NEW-BULB.light.\(power)", value: .bool(true)),
        ])
    }

    func testSharedWithListsOtherAutomationsOnly() throws {
        let users = [M.TriggerRef(id: "AUTO-1", name: "Evening"), M.TriggerRef(id: "AUTO-2", name: "Night")]
        let p = try XCTUnwrap(plan(set([row(1, power, .bool(true))], usedBy: users), [colorBulb]))
        XCTAssertEqual(p.sharedWith, [M.TriggerRef(id: "AUTO-2", name: "Night")])
    }

    func testSharedVisibleSetIsAppliedOnce() {
        let shared = set([row(1, power, .bool(true))], usedBy: [.init(id: "AUTO-1", name: "Evening"), .init(id: "AUTO-2", name: "Night")])
        let plans = M.plan(automations: [automation([shared]), automation([shared], id: "AUTO-2", name: "Night")],
                           old: old, replacements: [colorBulb])
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(M.setsToApply(plans).map(\.actionSetID), ["SET-1"])
        let report = M.report(home: "Home", old: old, replacements: [colorBulb], automationFilter: nil, plans: plans,
                              unattachedScenes: [], applyResults: nil, warnings: [])
        let summary = report["summary"] as? [String: Any]
        XCTAssertEqual(summary?["action_sets"] as? Int, 1)
        XCTAssertEqual(summary?["automations"] as? Int, 2)
        XCTAssertEqual(report["dry_run"] as? Bool, true)
    }

    func testBlockedSetsAreNotApplied() throws {
        let blocked = try XCTUnwrap(plan(set([row(1, hue, .int(1))]), [plainSwitch]))
        XCTAssertTrue(M.setsToApply([M.AutomationPlan(automation: automation([]), sets: [blocked])]).isEmpty)
    }

    // MARK: - Manual steps and fallback output

    func testManualStepsForHiddenSet() throws {
        let rows = [row(1, power, .bool(true)), row(2, brightness, .int(50))]
        let p = try XCTUnwrap(plan(set(rows, visible: false), [colorBulb]))
        XCTAssertEqual(p.manualSteps.map(\.action),
                       ["open_automation", "remove_accessory", "add_accessory", "set_characteristic", "set_characteristic", "save"])
        XCTAssertEqual(p.manualSteps.map(\.step), Array(1...6))
        XCTAssertEqual(p.manualSteps[0].fields["automation_id"], "AUTO-1")
        XCTAssertEqual(p.manualSteps[1].fields["accessory_id"], oldID)
        XCTAssertEqual(p.manualSteps[2].fields["accessory_id"], "NEW-BULB")
        XCTAssertEqual(p.manualSteps[4].fields["characteristic"], "brightness")
        XCTAssertEqual(p.manualSteps[4].fields["value"], "50")
        XCTAssertEqual(p.manualSteps[4].text, "Set 'Acc NEW-BULB' brightness to 50.")
    }

    func testManualStepsIncludeBlockingIssuesAndSkipUnusedReplacements() throws {
        let p = try XCTUnwrap(plan(set([row(1, hue, .int(200))], visible: false), [plainSwitch]))
        XCTAssertFalse(p.manualSteps.contains { $0.action == "add_accessory" })
        XCTAssertTrue(p.manualSteps.contains { $0.action == "review_issue" && $0.fields["kind"] == "no_replacement_characteristic" })
    }

    func testHiddenJSONCarriesIssueFallbackShape() throws {
        let rows = [row(1, power, .bool(true)), row(2, brightness, .int(50)), row(3, colorTemp, .int(312))]
        let a = automation([set(rows, visible: false)])
        let p = try XCTUnwrap(M.plan(set: a.actionSets[0], automation: a, old: old, replacements: [colorBulb]))
        let json = M.json(p, automation: a, apply: nil)
        XCTAssertEqual(json["status"] as? String, "unsupported")
        XCTAssertEqual(json["reason"] as? String, "hidden_action_set_requires_private_spi")
        XCTAssertEqual((json["automation"] as? [String: String])?["uuid"], "AUTO-1")
        XCTAssertEqual(json["remove_accessories"] as? [String], [oldID])
        XCTAssertEqual(json["add_accessories"] as? [String], ["NEW-BULB"])
        let chars = try XCTUnwrap(json["characteristics"] as? [String: Any])
        XCTAssertEqual(chars["power"] as? Bool, true)
        XCTAssertEqual(chars["brightness"] as? Int, 50)
        XCTAssertEqual(chars["color_temperature"] as? Int, 312)
        XCTAssertEqual((json["manual_steps"] as? [[String: Any]])?.first?["action"] as? String, "open_automation")
        XCTAssertNotNil(json["rollback"])
        XCTAssertNil(json["shared_with"])
        XCTAssertTrue(try JSONSerialization.data(withJSONObject: json).count > 0)
    }

    func testCharacteristicSummaryKeepsDistinctValuesAsArray() {
        let rows = [row(1, service: "g1", power, .bool(true)), row(2, service: "g2", power, .bool(false)),
                    row(3, service: "g3", power, .int(1))]
        let summary = M.characteristicSummary(rows)
        XCTAssertEqual((summary["power"] as? [Any])?.count, 2)
    }

    func testVisibleJSONHasSharingAndNoManualSteps() throws {
        let a = automation([set([row(1, power, .bool(true))])])
        let p = try XCTUnwrap(M.plan(set: a.actionSets[0], automation: a, old: old, replacements: [colorBulb]))
        let json = M.json(p, automation: a, apply: nil)
        XCTAssertEqual(json["classification"] as? String, "visible_scene")
        XCTAssertNotNil(json["shared_with"])
        XCTAssertNil(json["manual_steps"])
    }

    // MARK: - Verification

    func testVerifyExactMatch() {
        let e = [M.ExpectedAction(characteristicID: "A", value: .int(50)), M.ExpectedAction(characteristicID: "B", value: .bool(true))]
        XCTAssertTrue(M.verify(expected: e, actual: e.reversed()).verified)
    }

    private func expect(_ id: String, _ value: M.Value) -> M.ExpectedAction {
        M.ExpectedAction(characteristicID: id, value: value)
    }

    func testVerifyNumericEquivalence() {
        let expected: [M.ExpectedAction] = [expect("A", .bool(true)), expect("B", .int(50))]
        let actual: [M.ExpectedAction] = [expect("a", .int(1)), expect("B", .double(50.0))]
        XCTAssertTrue(M.verify(expected: expected, actual: actual).verified)
    }

    func testVerifyReportsMissingAndUnexpected() {
        let expected: [M.ExpectedAction] = [expect("A", .int(50)), expect("B", .int(1))]
        let actual: [M.ExpectedAction] = [expect("A", .int(40)), expect("B", .int(1)), expect("C", .int(1))]
        let v = M.verify(expected: expected, actual: actual)
        XCTAssertFalse(v.verified)
        XCTAssertEqual(v.missing, [expect("A", .int(50))])
        XCTAssertEqual(v.unexpected, [expect("A", .int(40)), expect("C", .int(1))])
    }

    func testVerifyIsAMultiset() {
        let one = M.ExpectedAction(characteristicID: "A", value: .int(1))
        XCTAssertFalse(M.verify(expected: [one], actual: [one, one]).verified)
        XCTAssertFalse(M.verify(expected: [one, one], actual: [one]).verified)
    }

    // MARK: - Values

    func testValueFromHomeKitObjects() {
        XCTAssertEqual(M.Value(any: NSNumber(value: true)), .bool(true))
        XCTAssertEqual(M.Value(any: NSNumber(value: 50)), .int(50))
        XCTAssertEqual(M.Value(any: NSNumber(value: 50.0)), .int(50))
        XCTAssertEqual(M.Value(any: NSNumber(value: 20.5)), .double(20.5))
        XCTAssertEqual(M.Value(any: "abc" as NSString), .string("abc"))
    }

    func testValueParsing() {
        XCTAssertEqual(M.Value(parsing: "true"), .bool(true))
        XCTAssertEqual(M.Value(parsing: " 50 "), .int(50))
        XCTAssertEqual(M.Value(parsing: "20.5"), .double(20.5))
        XCTAssertEqual(M.Value(parsing: "Locked"), .string("Locked"))
        XCTAssertFalse(M.Value.string("1").matches(.int(1)))
    }

    // MARK: - Old accessory resolution (review: restricted accessories)

    func testRestrictedHitIsRejectedEvenForAUUIDQuery() {
        let hit = M.LookupHit(id: oldID, name: "Hidden Lamp", room: nil, allowed: false)
        XCTAssertEqual(M.resolveOld(query: oldID, hit: hit), .restricted,
                       "a filtered accessory must not fall back to 'already removed'")
    }

    func testAllowedHitResolvesAsPresent() {
        let hit = M.LookupHit(id: oldID, name: "Old Lamp", room: "Kitchen", allowed: true)
        XCTAssertEqual(M.resolveOld(query: "Old Lamp", hit: hit),
                       .resolved(M.OldAccessory(id: oldID, name: "Old Lamp", room: "Kitchen", present: true)))
    }

    func testUUIDFallbackOnlyOnLookupMiss() {
        let gone = "8a1d0000-0000-0000-0000-000000000009"
        XCTAssertEqual(M.resolveOld(query: " \(gone) ", hit: nil),
                       .resolved(M.OldAccessory(id: gone.uppercased(), name: nil, room: nil, present: false)))
        XCTAssertEqual(M.resolveOld(query: "Old Lamp", hit: nil), .notFound)
    }

    func testOnlyOldAccessoryRowsAreRemovedAndOnlyReplacementsReceiveAdditions() throws {
        let restricted = row(7, accessory: "RESTRICTED", service: "light", power, .bool(true))
        let p = try XCTUnwrap(plan(set([row(1, power, .bool(true)), restricted]), [colorBulb]))
        XCTAssertFalse(p.removals.contains { $0.accessoryID == "RESTRICTED" })
        XCTAssertTrue(p.additions.allSatisfy { $0.accessoryID == "NEW-BULB" })
        XCTAssertTrue(p.expected.contains(M.ExpectedAction(characteristicID: restricted.characteristicID, value: .bool(true))))
    }

    // MARK: - Trigger-only dependencies (review)

    private func triggerOnly(_ watches: Bool) -> M.AutomationSnapshot {
        let lights = set([row(1, accessory: "LIGHT", power, .bool(true))], id: "SET-LIGHT",
                         usedBy: [M.TriggerRef(id: "MOTION", name: "Motion Lights")])
        return M.AutomationSnapshot(id: "MOTION", name: "Motion Lights", enabled: true, triggerType: "characteristic",
                                    triggerSummary: "Old Sensor motion_detected = true",
                                    triggerUsesOldAccessory: watches, actionSets: [lights])
    }

    func testTriggerOnlyAutomationIsKeptAndWarned() throws {
        let plans = M.plan(automations: [triggerOnly(true)], old: old, replacements: [colorBulb])
        let plan = try XCTUnwrap(plans.first)
        XCTAssertTrue(plan.triggerOnly)
        XCTAssertTrue(plan.sets.isEmpty)
        XCTAssertTrue(M.setsToApply(plans).isEmpty)
        XCTAssertTrue(M.warnings(old: old, plans: plans).contains { $0.contains("triggered by the old accessory") })

        let report = M.report(home: "Home", old: old, replacements: [colorBulb], automationFilter: nil, plans: plans,
                              unattachedScenes: [], applyResults: nil, warnings: [])
        let auto = try XCTUnwrap((report["automations"] as? [[String: Any]])?.first)
        XCTAssertEqual(auto["trigger_only"] as? Bool, true)
        XCTAssertEqual(auto["trigger_uses_old_accessory"] as? Bool, true)
        XCTAssertEqual((auto["action_sets"] as? [[String: Any]])?.count, 0)
        let summary = try XCTUnwrap(report["summary"] as? [String: Any])
        XCTAssertEqual(summary["trigger_only"] as? Int, 1)
        XCTAssertEqual(summary["action_sets"] as? Int, 0)
    }

    func testUnrelatedAutomationIsStillLeftOut() {
        XCTAssertTrue(M.plan(automations: [triggerOnly(false)], old: old, replacements: [colorBulb]).isEmpty)
    }

    func testAutomationWithSetsIsNotTriggerOnly() throws {
        let plan = try XCTUnwrap(M.plan(automations: [automation([set([row(1, power, .bool(true))])])],
                                        old: old, replacements: [colorBulb]).first)
        XCTAssertFalse(plan.triggerOnly)
    }

    // MARK: - Warnings and report

    func testWarnings() throws {
        let gone = M.OldAccessory(id: oldID, name: nil, room: nil, present: false)
        let hiddenSet = set([row(1, power, .bool(true))], visible: false)
        var a = automation([hiddenSet])
        a = M.AutomationSnapshot(id: a.id, name: a.name, enabled: a.enabled, triggerType: a.triggerType,
                                 triggerSummary: a.triggerSummary, triggerUsesOldAccessory: true, actionSets: a.actionSets)
        let plans = M.plan(automations: [a], old: gone, replacements: [colorBulb])
        let warnings = M.warnings(old: gone, plans: plans)
        XCTAssertEqual(warnings.count, 3)
        XCTAssertTrue(warnings.contains { $0.contains("not in this home") })
        XCTAssertTrue(warnings.contains { $0.contains("triggered by the old accessory") })
        XCTAssertTrue(warnings.contains { $0.contains("private SPI entitlement") })
    }

    func testApplyReportSerializesVerification() throws {
        let plans = M.plan(automations: [automation([set([row(1, power, .bool(true))])])], old: old, replacements: [colorBulb])
        let result = M.ApplyResult(status: .applied, addedActions: ["NEW-ACTION"], removedActionIDs: ["action-1"],
                                   verification: M.Verification(missing: [], unexpected: []), error: nil, note: nil)
        let report = M.report(home: "Home", old: old, replacements: [colorBulb], automationFilter: "Evening", plans: plans,
                              unattachedScenes: [(id: "S", name: "Loose", actionCount: 1)],
                              applyResults: ["SET-1": result], warnings: [])
        XCTAssertEqual(report["mode"] as? String, "apply")
        XCTAssertEqual(report["automation_filter"] as? String, "Evening")
        let summary = try XCTUnwrap(report["summary"] as? [String: Any])
        XCTAssertEqual(summary["applied"] as? Int, 1)
        XCTAssertEqual(summary["verified"] as? Int, 1)
        XCTAssertEqual(summary["failed"] as? Int, 0)
        let sets = try XCTUnwrap(((report["automations"] as? [[String: Any]])?.first?["action_sets"]) as? [[String: Any]])
        let apply = try XCTUnwrap(sets.first?["apply"] as? [String: Any])
        XCTAssertEqual((apply["verification"] as? [String: Any])?["verified"] as? Bool, true)
        XCTAssertEqual((report["unattached_scenes"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue(try JSONSerialization.data(withJSONObject: report).count > 0)
    }
}
