import Testing
@testable import homeclaw_cli

// Issue #119: `automations rewire --dry-run` must echo the resolved automation UUID
// and the resolved add/remove scene UUIDs, so a caller can prove which trigger and
// scenes a real run would touch before committing to it. The resolution itself
// runs in the Catalyst app (HomeKitManager.matchIdentifier), which `swift test`
// can't reach; these tests pin the CLI half of the contract.

@Suite("RewireAutomation.formatResult")
struct RewireFormatTests {
    static let autoID = "A1B2C3D4-0000-0000-0000-000000000001"
    static let newScene = "5CE9E000-0000-0000-0000-00000000000A"
    static let oldScene = "5CE9E000-0000-0000-0000-00000000000B"

    @Test("dry run echoes the automation UUID and the resolved scene UUIDs")
    func dryRunIncludesIDs() {
        let lines = RewireAutomation.formatResult([
            "dry_run": true,
            "id": Self.autoID,
            "name": "Morning Lights",
            "before": ["Old Scene"],
            "before_ids": [Self.oldScene],
            "to_add": ["New Scene"],
            "to_add_ids": [Self.newScene],
            "to_remove": ["Old Scene"],
            "to_remove_ids": [Self.oldScene],
            "warnings": [String](),
        ], fallbackName: "morning lights")

        #expect(lines == [
            "DRY RUN — Morning Lights (\(Self.autoID))",
            "  Currently attached: Old Scene",
            "  Would add:    New Scene (\(Self.newScene))",
            "  Would remove: Old Scene (\(Self.oldScene))",
        ])
    }

    @Test("real run header carries the automation UUID")
    func realRunIncludesID() {
        let lines = RewireAutomation.formatResult([
            "dry_run": false,
            "id": Self.autoID,
            "name": "Morning Lights",
            "before": ["Old Scene"],
            "after": ["New Scene"],
        ], fallbackName: "x")
        #expect(lines.first == "Rewired 'Morning Lights' (\(Self.autoID))")
        #expect(lines.contains("  After:  New Scene"))
    }

    @Test("older app builds without *_ids fall back to names only")
    func missingIDsFallBack() {
        let lines = RewireAutomation.formatResult([
            "dry_run": true,
            "name": "Porch",
            "before": ["A"],
            "to_add": ["B"],
            "to_remove": ["A"],
        ], fallbackName: "Porch")
        #expect(lines[0] == "DRY RUN — Porch")
        #expect(lines[2] == "  Would add:    B")
        #expect(lines[3] == "  Would remove: A")
    }

    @Test("mismatched name/id arrays never mis-pair a UUID with the wrong scene")
    func mismatchedIDsFallBack() {
        let text = RewireAutomation.scenesWithIDs(
            ["to_add": ["B", "C"], "to_add_ids": [Self.newScene]],
            names: "to_add", ids: "to_add_ids")
        #expect(text == "B, C")
    }

    @Test("warnings render after the summary")
    func warnings() {
        let lines = RewireAutomation.formatResult([
            "dry_run": true, "id": Self.autoID, "name": "Porch",
            "warnings": ["Scene not attached to this automation (remove): Nope"],
        ], fallbackName: "Porch")
        #expect(lines.suffix(2) == ["Warnings:", "  ⚠ Scene not attached to this automation (remove): Nope"])
    }

    @Test("falls back to the caller's identifier when the result has no name")
    func fallbackName() {
        let lines = RewireAutomation.formatResult(["dry_run": true], fallbackName: Self.autoID)
        #expect(lines.first == "DRY RUN — \(Self.autoID)")
    }
}
