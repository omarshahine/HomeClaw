import ArgumentParser
import Testing
@testable import homeclaw_cli

// TestFlight feedback (build 195): the Home app gives the hidden, trigger-owned
// action sets behind button automations an empty or opaque UUID-style name, so
// `scenes` and `automations` printed blanks and what looked like duplicate rows.

@Suite("Scene display names")
struct SceneDisplayTests {
    static let id = "7CE51C3D-2186-5399-A360-0D1FC92FF428"

    @Test("a named scene prints its name")
    func named() {
        #expect(sceneDisplayName("Morning Blinds", id: Self.id) == "Morning Blinds")
    }

    @Test("an empty or blank name falls back to the UUID")
    func unnamed() {
        #expect(sceneDisplayName("", id: Self.id) == "(unnamed \(Self.id))")
        #expect(sceneDisplayName("  ", id: Self.id) == "(unnamed \(Self.id))")
        #expect(sceneDisplayName(nil, id: nil) == "(unnamed)")
    }

    @Test("automation scene references never render a blank entry")
    func automationReferences() {
        let text = formatSceneReferences([
            "action_sets": [
                ["id": Self.id, "name": "", "hidden": true],
                ["id": "2EEC6E34-0F56-5215-B89E-2638641008F7", "name": "Morning Blinds"],
            ],
        ])
        #expect(text == "(unnamed \(Self.id)) (hidden), Morning Blinds")
    }

    @Test("hidden scenes show their ID so same-named sets stay distinguishable")
    func hiddenLineShowsID() {
        let line = Scenes.formatLine([
            "id": Self.id, "name": "BC1D50D7-100F-5ED7-8110-5A14FED588A5",
            "type": "user_defined", "action_count": 0, "hidden": true,
        ])
        #expect(line == "  BC1D50D7-100F-5ED7-8110-5A14FED588A5 (\(Self.id)) [user_defined, hidden] — 0 action(s)")
    }

    @Test("visible scenes keep the compact format")
    func visibleLine() {
        let line = Scenes.formatLine([
            "id": Self.id, "name": "Main Lights", "type": "user_defined", "action_count": 11,
        ])
        #expect(line == "  Main Lights [user_defined] — 11 action(s)")
    }
}

@Suite("Automation get rendering")
struct AutomationGetRenderingTests {
    @Test("presence events print their summary, not '?: ?'")
    func presence() {
        let line = GetAutomation.formatEventLine([
            "type": "presence", "trigger_type": "presence", "summary": "when the first person arrives",
        ])
        #expect(line == "  when the first person arrives")
    }

    @Test("button events keep the press and button index")
    func button() {
        let line = GetAutomation.formatEventLine([
            "type": "characteristic", "trigger_type": "button", "accessory": "Kitchen Remote",
            "press_type": "single_press", "service_index": 2,
        ])
        #expect(line == "  Kitchen Remote: single_press (button 2)")
    }

    @Test("sensor and threshold events show what they watch")
    func sensors() {
        #expect(GetAutomation.formatEventLine([
            "type": "characteristic", "trigger_type": "characteristic", "accessory": "Gate",
            "characteristic": "contact_state", "trigger_value": "open",
        ]) == "  Gate: contact_state = open")
        #expect(GetAutomation.formatEventLine([
            "type": "threshold", "trigger_type": "threshold", "accessory": "Porch",
            "characteristic": "current_light_level", "summary": "≤ 15 lux",
        ]) == "  Porch: current_light_level ≤ 15 lux")
    }

    @Test("hidden scenes with the same opaque name are told apart by ID")
    func hiddenLabelsCarryID() {
        let a = sceneLabel(["id": "AAAA", "name": "BC1D50D7", "hidden": true])
        let b = sceneLabel(["id": "BBBB", "name": "BC1D50D7", "hidden": true])
        #expect(a == "BC1D50D7 (AAAA)")
        #expect(a != b)
        #expect(sceneLabel(["id": "AAAA", "name": "Morning Blinds"]) == "Morning Blinds")
    }
}

@Suite("CommandFailure")
struct CommandFailureTests {
    @Test("runtime failures print only the message and exit 1")
    func runtimeFailure() {
        let error = CommandFailure("Accessory not found: Lamp")
        #expect(HomeKitCLI.fullMessage(for: error) == "Error: Accessory not found: Lamp")
        #expect(HomeKitCLI.exitCode(for: error) == .failure)
    }

    @Test("argument errors still carry usage and exit 64")
    func validationError() {
        let error = ValidationError("--duration must be a positive integer")
        #expect(HomeKitCLI.fullMessage(for: error).contains("Usage:"))
        #expect(HomeKitCLI.exitCode(for: error) == .validationFailure)
    }
}
