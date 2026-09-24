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

@Suite("CommandFailure")
struct CommandFailureTests {
    @Test("runtime failures carry only the message, so no usage block is printed")
    func messageOnly() {
        let error: Error = CommandFailure("Accessory not found: Lamp")
        #expect(error.localizedDescription == "Accessory not found: Lamp")
        #expect(!(error is ValidationError))
    }
}
