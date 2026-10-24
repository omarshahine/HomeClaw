import Foundation
import Testing
@testable import homeclaw_cli

/// Tests for the `automations edit` CLI parser, the socket-argument builder
/// (presence rules: absent vs. empty) and the human-readable summary.
@Suite("EditAutomation CLI")
struct EditAutomationTests {
    private func expectValidationFails(
        _ args: [String],
        mentioning expected: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            let cmd = try EditAutomation.parse(args)
            try cmd.validate()
            Issue.record("expected validation to fail mentioning '\(expected)'", sourceLocation: sourceLocation)
        } catch {
            let desc = String(describing: error)
            #expect(desc.contains(expected), "error '\(desc)' should mention '\(expected)'", sourceLocation: sourceLocation)
        }
    }

    // MARK: Validation

    @Test("rejects a call without any change")
    func rejectsNoChange() {
        expectValidationFails(["Porch Lights"], mentioning: "Nothing to edit")
        expectValidationFails(["Porch Lights", "--dry-run", "--json"], mentioning: "Nothing to edit")
    }

    @Test("rejects empty id and empty --name")
    func rejectsEmptyStrings() {
        expectValidationFails(["   ", "--name", "x"], mentioning: "id/name must be non-empty")
        expectValidationFails(["Porch Lights", "--name", "  "], mentioning: "--name must be non-empty")
    }

    @Test("rejects replace and clear of the same field together")
    func rejectsReplaceAndClear() {
        expectValidationFails(["A", "--days", "mon", "--every-day"], mentioning: "--every-day")
        expectValidationFails(["A", "--condition", "Door:contact_state:0", "--clear-conditions"], mentioning: "--clear-conditions")
        expectValidationFails(["A", "--time-after", "sunset", "--clear-time-window"], mentioning: "--clear-time-window")
        expectValidationFails(["A", "--duration", "60", "--clear-duration"], mentioning: "--clear-duration")
    }

    @Test("rejects --duration outside 1...86400")
    func rejectsDurationRange() {
        expectValidationFails(["A", "--duration", "0"], mentioning: "between 1 and 86400")
        expectValidationFails(["A", "--duration", "86401"], mentioning: "between 1 and 86400")
    }

    // MARK: Socket arguments

    @Test("only the given fields are sent")
    func sendsOnlyGivenFields() throws {
        let args = try EditAutomation.parse(["Porch Lights", "--name", "Porch at dusk"]).socketArgs()
        #expect(args["id"] as? String == "Porch Lights")
        #expect(args["new_name"] as? String == "Porch at dusk")
        #expect(args["dry_run"] as? Bool == false)
        for key in ["time", "weekdays", "conditions", "time_after", "time_before", "duration_seconds", "clear_duration"] {
            #expect(args[key] == nil, "\(key) should be absent")
        }
    }

    @Test("clear flags send empty arrays / clear_duration")
    func clearFlagsSendEmpty() throws {
        let args = try EditAutomation.parse(
            ["A", "--every-day", "--clear-conditions", "--clear-time-window", "--clear-duration"]
        ).socketArgs()
        #expect((args["weekdays"] as? [Int]) == [])
        #expect((args["conditions"] as? [[String: String]])?.isEmpty == true)
        #expect((args["time_after"] as? [String]) == [])
        #expect((args["time_before"] as? [String]) == [])
        #expect(args["clear_duration"] as? Bool == true)
    }

    @Test("one side of the time window sends both keys, so the whole window is replaced")
    func timeWindowReplacesBothSides() throws {
        let args = try EditAutomation.parse(["A", "--time-after", "sunset-30"]).socketArgs()
        #expect((args["time_after"] as? [String]) == ["sunset-30"])
        #expect((args["time_before"] as? [String]) == [])
    }

    @Test("parses time, days, conditions and duration")
    func parsesReplacements() throws {
        let args = try EditAutomation.parse([
            "Coffee", "--time", "06:45", "--days", "mon,sat",
            "--condition", "Front Door:contact_state:0", "--duration", "300", "--dry-run",
        ]).socketArgs()
        #expect(args["time"] as? String == "06:45")
        #expect((args["weekdays"] as? [Int]) == [2, 7])
        let conditions = args["conditions"] as? [[String: String]]
        #expect(conditions?.first?["accessory"] == "Front Door")
        #expect(conditions?.first?["value"] == "0")
        #expect(args["duration_seconds"] as? Int == 300)
        #expect(args["dry_run"] as? Bool == true)
    }

    @Test("rejects a malformed --time before contacting the socket")
    func rejectsBadTime() {
        #expect(throws: (any Error).self) {
            _ = try EditAutomation.parse(["A", "--time", "6:30"]).socketArgs()
        }
    }

    // MARK: Summary

    @Test("summary for a dry run with rename, new time and auto-filled days")
    func summaryDryRun() {
        let lines = EditAutomation.summaryLines([
            "dry_run": true,
            "changes": ["weekdays", "events", "name"],
            "before": ["name": "Hall Motion"],
            "planned": ["name": "Hall at dusk", "time": "sunset", "weekdays": [1, 2, 3, 4, 5, 6, 7], "weekdays_auto_filled": true],
            "replaced_trigger": ["trigger_type": "characteristic", "summary": "Hall Sensor motion_detected = true"],
        ], fallbackName: "Hall Motion")
        #expect(lines.first == "DRY RUN — would edit automation 'Hall Motion'")
        #expect(lines.contains("  Name: Hall Motion → Hall at dusk"))
        #expect(lines.contains("  Trigger: at sunset (replaces: Hall Sensor motion_detected = true)"))
        #expect(lines.contains { $0.hasPrefix("  Days: every day (auto-filled") })
    }

    @Test("summary for an applied edit lists conditions, removed auto-off and verification")
    func summaryApplied() {
        let lines = EditAutomation.summaryLines([
            "dry_run": false,
            "changes": ["predicate", "duration"],
            "before": ["name": "Porch"],
            "planned": [
                "name": "Porch",
                "conditions": [
                    ["type": "characteristic", "accessory": "Front Door", "property": "contact_state", "value": "0"],
                    ["type": "time", "summary": "after sunset"],
                ],
                "duration_seconds": NSNull(),
            ],
            "verified": false,
            "mismatches": ["predicate"],
        ], fallbackName: "Porch")
        #expect(lines.first == "Edited automation 'Porch'")
        #expect(lines.contains("    Front Door: contact_state = 0"))
        #expect(lines.contains("    after sunset"))
        #expect(lines.contains("  Auto-off: removed"))
        #expect(lines.contains { $0.contains("re-read differs from the plan (predicate)") })
    }

    @Test("summary for an edit that changes nothing")
    func summaryUnchanged() {
        let lines = EditAutomation.summaryLines(
            ["unchanged": true, "changes": [String](), "before": ["name": "Porch"], "planned": ["name": "Porch"]],
            fallbackName: "Porch")
        #expect(lines == ["No changes: 'Porch' already matches."])
    }
}
