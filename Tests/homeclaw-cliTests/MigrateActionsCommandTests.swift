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

    static var dryRun: [String: Any] { [
        "mode": "dry_run",
        "old_accessory": ["id": "OLD", "name": "Old Lamp", "present": true],
        "new_accessories": [["id": "NEW", "name": "New Lamp"]],
        "automations": [[
            "id": "AUTO", "name": "Evening", "enabled": true, "trigger_summary": "sunset",
            "trigger_uses_old_accessory": false,
            "action_sets": [
                [
                    "id": "SCENE", "name": "Evening Scene", "classification": "visible_scene", "status": "supported",
                    "shared_with": [["id": "AUTO2", "name": "Night"]],
                    "removals": [["accessory": "Old Lamp", "characteristic": "brightness", "value": 50]],
                    "additions": [["accessory": "New Lamp", "characteristic": "brightness", "value": 50]],
                    "issues": [[String: Any]](),
                ],
                [
                    "id": "HIDDEN", "name": "", "classification": "hidden", "status": "unsupported",
                    "reason": "hidden_action_set_requires_private_spi",
                    "removals": [["accessory": "Old Lamp", "characteristic": "power", "value": true]],
                    "additions": [["accessory": "New Lamp", "characteristic": "power", "value": true]],
                    "issues": [["kind": "missing_characteristic", "blocking": false, "detail": "New Lamp has no hue characteristic"]],
                    "manual_steps": [["step": 1, "text": "In the Home app, open Automations and select 'Evening' (sunset)."]],
                ],
            ],
        ]],
        "summary": ["automations": 1, "action_sets": 2, "supported": 1, "unsupported": 1, "blocked": 0],
        "warnings": ["Some visible scenes are shared with other automations."],
    ] }

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
        let lines = Cmd.formatResult(["mode": "dry_run", "old_accessory": ["id": "X", "present": false], "automations": [[String: Any]]()])
        #expect(lines.contains("  Replace: X (not in home)"))
        #expect(lines.contains("No automation action sets write to the old accessory."))
    }

    static func applied(verified: Bool, failed: Int = 0) -> [String: Any] {
        [
            "mode": "apply",
            "automations": [["action_sets": [[
                "id": "SCENE", "classification": "visible_scene", "status": "supported",
                "apply": ["status": "applied", "verification": ["verified": verified]],
            ]]]],
            "summary": ["failed": failed, "applied": 1, "verified": verified ? 1 : 0],
        ]
    }

    @Test("apply exit-code contract: verified succeeds, unverified or failed throws")
    func applyFailure() {
        #expect(Cmd.applyFailure(Self.applied(verified: true)) == nil)
        #expect(Cmd.applyFailure(Self.applied(verified: false)) != nil)
        #expect(Cmd.applyFailure(Self.applied(verified: true, failed: 1)) != nil)
        #expect(Cmd.formatResult(Self.applied(verified: false)).contains("    Apply: applied, NOT verified"))
    }
}
