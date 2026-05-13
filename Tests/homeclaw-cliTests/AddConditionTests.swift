import Testing
@testable import homeclaw_cli

/// Tests for the `automations add-condition` CLI parser.
///
/// Only the CLI-layer validation surface is testable from this target — the manager
/// and SocketServer halves live in the `homeclaw` app target (Catalyst-only, HomeKit
/// entitlement required) and are exercised end-to-end via `swift run homeclaw-cli`
/// against a running app, not from unit tests. The empty-string and whitespace-only
/// rejection paths covered here mirror the SocketServer-side `Missing or empty` guard
/// in `SocketServer.swift` so a malformed CLI invocation fails fast at the parser.
@Suite("AddAutomationCondition CLI parser")
struct AddConditionTests {
    @Test("parses all required flags")
    func parsesRequiredFlags() throws {
        let cmd = try AddAutomationCondition.parse([
            "Porch Lights",
            "--accessory", "Front Door",
            "--property", "contact_state",
            "--value", "0",
        ])
        #expect(cmd.id == "Porch Lights")
        #expect(cmd.accessory == "Front Door")
        #expect(cmd.property == "contact_state")
        #expect(cmd.value == "0")
        #expect(cmd.dryRun == false)
        #expect(cmd.json == false)
        #expect(cmd.home == nil)
    }

    @Test("accepts --dry-run and --json flags")
    func parsesOptionalFlags() throws {
        let cmd = try AddAutomationCondition.parse([
            "Porch Lights",
            "--accessory", "Front Door",
            "--property", "contact_state",
            "--value", "0",
            "--dry-run",
            "--json",
        ])
        #expect(cmd.dryRun == true)
        #expect(cmd.json == true)
    }

    @Test("accepts --home option")
    func parsesHome() throws {
        let cmd = try AddAutomationCondition.parse([
            "auto-1",
            "--accessory", "Sensor",
            "--property", "motion_detected",
            "--value", "true",
            "--home", "My Home",
        ])
        #expect(cmd.home == "My Home")
    }

    /// Assert that `cmd.validate()` throws and that the error message mentions `expected`.
    /// `AddAutomationCondition.validate()` throws `ValidationError` directly — when used
    /// via `ParsableCommand.parse(...)` the runner wraps it in a `CommandError`, but
    /// invoking `validate()` directly throws the underlying error. We match on
    /// `String(describing:)` so either case is acceptable.
    private func expectValidationFails(
        _ args: [String],
        mentioning expected: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            let cmd = try AddAutomationCondition.parse(args)
            try cmd.validate()
            Issue.record("expected validation to fail mentioning '\(expected)'", sourceLocation: sourceLocation)
        } catch {
            let desc = String(describing: error)
            #expect(desc.contains(expected), "error '\(desc)' should mention '\(expected)'", sourceLocation: sourceLocation)
        }
    }

    @Test("rejects empty positional id")
    func rejectsEmptyId() {
        expectValidationFails(
            ["", "--accessory", "Front Door", "--property", "contact_state", "--value", "0"],
            mentioning: "id/name must be non-empty"
        )
    }

    @Test("rejects whitespace-only id")
    func rejectsWhitespaceId() {
        expectValidationFails(
            ["   ", "--accessory", "Front Door", "--property", "contact_state", "--value", "0"],
            mentioning: "id/name must be non-empty"
        )
    }

    @Test("rejects empty --accessory")
    func rejectsEmptyAccessory() {
        expectValidationFails(
            ["Porch Lights", "--accessory", "", "--property", "contact_state", "--value", "0"],
            mentioning: "--accessory must be non-empty"
        )
    }

    @Test("rejects whitespace-only --accessory")
    func rejectsWhitespaceAccessory() {
        expectValidationFails(
            ["Porch Lights", "--accessory", "   ", "--property", "contact_state", "--value", "0"],
            mentioning: "--accessory must be non-empty"
        )
    }

    @Test("rejects empty --property")
    func rejectsEmptyProperty() {
        expectValidationFails(
            ["Porch Lights", "--accessory", "Front Door", "--property", "", "--value", "0"],
            mentioning: "--property must be non-empty"
        )
    }

    @Test("rejects whitespace-only --property")
    func rejectsWhitespaceProperty() {
        expectValidationFails(
            ["Porch Lights", "--accessory", "Front Door", "--property", "   ", "--value", "0"],
            mentioning: "--property must be non-empty"
        )
    }

    @Test("rejects empty --value")
    func rejectsEmptyValue() {
        expectValidationFails(
            ["Porch Lights", "--accessory", "Front Door", "--property", "contact_state", "--value", ""],
            mentioning: "--value must be non-empty"
        )
    }

    @Test("rejects whitespace-only --value")
    func rejectsWhitespaceValue() {
        expectValidationFails(
            ["Porch Lights", "--accessory", "Front Door", "--property", "contact_state", "--value", "   "],
            mentioning: "--value must be non-empty"
        )
    }

    @Test("accepts numeric-looking values without coercion")
    func acceptsNumericValueAsString() throws {
        let cmd = try AddAutomationCondition.parse([
            "auto-1",
            "--accessory", "Thermostat",
            "--property", "current_temperature",
            "--value", "72.5",
        ])
        try cmd.validate()
        #expect(cmd.value == "72.5")
    }

    @Test("missing required flag rejected by ArgumentParser")
    func rejectsMissingProperty() {
        #expect(throws: (any Error).self) {
            _ = try AddAutomationCondition.parse([
                "auto-1",
                "--accessory", "Sensor",
                "--value", "true",
            ])
        }
    }

    // MARK: --room

    @Test("accepts --room when provided")
    func parsesRoom() throws {
        let cmd = try AddAutomationCondition.parse([
            "auto-1",
            "--accessory", "Light",
            "--property", "power",
            "--value", "true",
            "--room", "Kitchen",
        ])
        try cmd.validate()
        #expect(cmd.room == "Kitchen")
    }

    @Test("--room absent → validate() passes with cmd.room == nil")
    func roomAbsentValidates() throws {
        let cmd = try AddAutomationCondition.parse([
            "auto-1",
            "--accessory", "Light",
            "--property", "power",
            "--value", "true",
        ])
        try cmd.validate()
        #expect(cmd.room == nil)
    }

    @Test("rejects empty --room")
    func rejectsEmptyRoom() {
        expectValidationFails(
            ["Porch Lights", "--accessory", "Front Door", "--property", "contact_state", "--value", "0", "--room", ""],
            mentioning: "--room must be non-empty"
        )
    }

    @Test("rejects whitespace-only --room")
    func rejectsWhitespaceRoom() {
        expectValidationFails(
            ["Porch Lights", "--accessory", "Front Door", "--property", "contact_state", "--value", "0", "--room", "   "],
            mentioning: "--room must be non-empty"
        )
    }
}
