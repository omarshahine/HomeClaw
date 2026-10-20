import ArgumentParser
import Foundation
import Testing
@testable import homeclaw_cli

// Issue #120: `automations migrate-actions --replace-accessory <old>=<new>[,<new>...]`.
// The planning runs in the Catalyst app (ActionMigration, tested in HomeClawTests);
// these pin the CLI half: argument parsing, rendering, and the exit-code contract.

@Suite("MigrateAutomationActions")
struct MigrateActionsCommandTests {
    typealias Cmd = MigrateAutomationActions

    @Test("one replacement")
    func single() throws {
        #expect(try Cmd.parseReplacement("Old Lamp=New Lamp") == .init(old: "Old Lamp", new: ["New Lamp"]))
    }

    @Test("several replacements, whitespace trimmed")
    func several() throws {
        #expect(try Cmd.parseReplacement(" A-UUID = B-UUID , C-UUID ") == .init(old: "A-UUID", new: ["B-UUID", "C-UUID"]))
    }

    @Test("malformed values are validation errors", arguments: [
        "OldOnly", "=New", "Old=", "Old=New,", "Old=,New", "A=B=C", "Old=New,new", "Lamp=lamp", "",
    ])
    func malformed(_ raw: String) {
        #expect(throws: ValidationError.self) { try Cmd.parseReplacement(raw) }
    }

    @Test("argument parsing: plan-only by default, --apply opts in")
    func flags() throws {
        let plan = try Cmd.parse(["--replace-accessory", "A=B"])
        #expect(plan.apply == false)
        #expect(plan.automation == nil)
        let apply = try Cmd.parse(["--replace-accessory", "A=B,C", "--automation", "Evening", "--home", "Cabin", "--apply", "--json"])
        #expect(apply.apply)
        #expect(apply.automation == "Evening")
        #expect(apply.home == "Cabin")
        #expect(apply.json)
    }

    @Test("--replace-accessory is required and validated at parse time")
    func requiredAndValidated() {
        #expect(throws: (any Error).self) { try Cmd.parse([]) }
        #expect(throws: (any Error).self) { try Cmd.parse(["--replace-accessory", "nonsense"]) }
        #expect(throws: (any Error).self) { try Cmd.parse(["--replace-accessory", "A=B", "--automation", " "]) }
    }

    @Test("registered under automations")
    func registered() {
        #expect(Automations.configuration.subcommands.contains { $0 == Cmd.self })
    }

    // Built from small, explicitly typed pieces: one large heterogeneous literal
    // times out the type checker on older toolchains (CI's macos-26 runner).
    static var dryRun: [String: Any] {
        let oldRow: [String: Any] = ["accessory": "Old Lamp", "characteristic": "brightness", "value": 50]
        let newRow: [String: Any] = ["accessory": "New Lamp", "characteristic": "brightness", "value": 50]
        let shared: [String: Any] = ["id": "AUTO2", "name": "Night"]
        var scene: [String: Any] = [:]
        scene["id"] = "SCENE"
        scene["name"] = "Evening Scene"
        scene["classification"] = "visible_scene"
        scene["status"] = "supported"
        scene["shared_with"] = [shared]
        scene["removals"] = [oldRow]
        scene["additions"] = [newRow]
        scene["issues"] = [[String: Any]]()

        let oldPower: [String: Any] = ["accessory": "Old Lamp", "characteristic": "power", "value": true]
        let newPower: [String: Any] = ["accessory": "New Lamp", "characteristic": "power", "value": true]
        let issue: [String: Any] = [
            "kind": "missing_characteristic", "blocking": false, "detail": "New Lamp has no hue characteristic",
        ]
        let step: [String: Any] = ["step": 1, "text": "In the Home app, open Automations and select 'Evening' (sunset)."]
        var hidden: [String: Any] = [:]
        hidden["id"] = "HIDDEN"
        hidden["name"] = ""
        hidden["classification"] = "hidden"
        hidden["status"] = "unsupported"
        hidden["reason"] = "hidden_action_set_requires_private_spi"
        hidden["removals"] = [oldPower]
        hidden["additions"] = [newPower]
        hidden["issues"] = [issue]
        hidden["manual_steps"] = [step]

        var automation: [String: Any] = [:]
        automation["id"] = "AUTO"
        automation["name"] = "Evening"
        automation["enabled"] = true
        automation["trigger_summary"] = "sunset"
        automation["trigger_uses_old_accessory"] = false
        automation["action_sets"] = [scene, hidden]

        let old: [String: Any] = ["id": "OLD", "name": "Old Lamp", "present": true]
        let new: [String: Any] = ["id": "NEW", "name": "New Lamp"]
        let summary: [String: Any] = ["automations": 1, "action_sets": 2, "supported": 1, "unsupported": 1, "blocked": 0]
        var result: [String: Any] = [:]
        result["mode"] = "dry_run"
        result["old_accessory"] = old
        result["new_accessories"] = [new]
        result["automations"] = [automation]
        result["summary"] = summary
        result["warnings"] = ["Some visible scenes are shared with other automations."]
        return result
    }

    @Test("dry run rendering shows classification, status, rows and manual steps")
    func rendersDryRun() {
        let lines = Cmd.formatResult(Self.dryRun)
        #expect(lines[0].hasPrefix("DRY RUN"))
        #expect(lines.contains("  Replace: Old Lamp (OLD)"))
        #expect(lines.contains("  [supported] scene 'Evening Scene' (SCENE)"))
        #expect(lines.contains("    Shared with: Night"))
        #expect(lines.contains("    - remove Old Lamp brightness = 50"))
        #expect(lines.contains("    + add    New Lamp power = true"))
        #expect(lines.contains("  [unsupported] hidden action set (HIDDEN): hidden_action_set_requires_private_spi"))
        #expect(lines.contains("    ~ missing_characteristic: New Lamp has no hue characteristic"))
        #expect(lines.contains("      1. In the Home app, open Automations and select 'Evening' (sunset)."))
        #expect(lines.contains("1 automation(s), 2 action set(s): 1 supported, 1 unsupported, 0 blocked"))
        #expect(Cmd.applyFailure(Self.dryRun) == nil)
    }

    @Test("empty plan says so")
    func emptyPlan() {
        let old: [String: Any] = ["id": "X", "present": false]
        var result: [String: Any] = [:]
        result["mode"] = "dry_run"
        result["old_accessory"] = old
        result["automations"] = [[String: Any]]()
        let lines = Cmd.formatResult(result)
        #expect(lines.contains("  Replace: X (not in home)"))
        #expect(lines.contains("No automation action sets write to the old accessory."))
    }

    static func applied(verified: Bool, failed: Int = 0) -> [String: Any] {
        let verification: [String: Any] = ["verified": verified]
        let apply: [String: Any] = ["status": "applied", "verification": verification]
        var set: [String: Any] = [:]
        set["id"] = "SCENE"
        set["classification"] = "visible_scene"
        set["status"] = "supported"
        set["apply"] = apply
        let automation: [String: Any] = ["action_sets": [set]]
        let summary: [String: Any] = ["failed": failed, "applied": 1, "verified": verified ? 1 : 0]
        var result: [String: Any] = [:]
        result["mode"] = "apply"
        result["automations"] = [automation]
        result["summary"] = summary
        return result
    }

    @Test("apply exit-code contract: verified succeeds, unverified or failed throws")
    func applyFailure() {
        #expect(Cmd.applyFailure(Self.applied(verified: true)) == nil)
        #expect(Cmd.applyFailure(Self.applied(verified: false)) != nil)
        #expect(Cmd.applyFailure(Self.applied(verified: true, failed: 1)) != nil)
        #expect(Cmd.formatResult(Self.applied(verified: false)).contains("    Apply: applied, NOT verified"))
    }
}
