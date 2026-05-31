#if !APP_STORE
import Testing
@testable import homeclaw_cli

// The TUI (`homeclaw-cli ui`) is excluded from App Store builds because SwiftTUI
// needs raw terminal mode the sandbox blocks, so these are guarded by the same
// `#if !APP_STORE` that gates the types. They cover the pure state→display logic
// on AccessoryNode and the Ui.parseRooms socket-payload decoder — no terminal,
// no socket required.

private func node(_ category: String, _ state: [String: String]) -> AccessoryNode {
    AccessoryNode(id: "id-1", name: "Test", category: category, state: state)
}

// MARK: - stateSummary

@Suite("AccessoryNode.stateSummary")
struct StateSummaryTests {
    @Test("power state is capitalised")
    func power() {
        #expect(node("lightbulb", ["power_state": "on"]).stateSummary == "On")
        #expect(node("outlet", ["power_state": "off"]).stateSummary == "Off")
    }

    @Test("temperature is shown verbatim (already formatted by the server)")
    func temperature() {
        #expect(node("thermostat", ["current_temperature": "70.5°F"]).stateSummary == "70.5°F")
    }

    @Test("placeholder '--' temperature is skipped")
    func placeholderTemp() {
        #expect(node("thermostat", ["current_temperature": "--"]).stateSummary == "")
    }

    @Test("position renders as a percentage")
    func position() {
        #expect(node("window_covering", ["current_position": "100"]).stateSummary == "100%")
    }

    @Test("motion only summarises when actually detected")
    func motion() {
        #expect(node("sensor", ["motion_detected": "yes"]).stateSummary == "Motion")
        #expect(node("sensor", ["motion_detected": "true"]).stateSummary == "Motion")
        #expect(node("sensor", ["motion_detected": "no"]).stateSummary == "")
    }

    @Test("power takes precedence over other characteristics")
    func precedence() {
        let n = node("lightbulb", ["power_state": "on", "current_temperature": "70°F"])
        #expect(n.stateSummary == "On")
    }

    @Test("empty state yields empty summary")
    func empty() {
        #expect(node("other", [:]).stateSummary == "")
    }
}

// MARK: - statusGlyph

@Suite("AccessoryNode.statusGlyph")
struct StatusGlyphTests {
    @Test("power on/off → filled/empty circle")
    func power() {
        #expect(node("lightbulb", ["power_state": "on"]).statusGlyph == "●")
        #expect(node("lightbulb", ["power_state": "off"]).statusGlyph == "○")
    }

    @Test("lock states map to filled / half / empty")
    func lock() {
        #expect(node("lock", ["lock_current_state": "locked"]).statusGlyph == "●")
        #expect(node("lock", ["lock_current_state": "unlocked"]).statusGlyph == "◐")
    }

    @Test("temperature-bearing accessories show the half glyph")
    func temperature() {
        #expect(node("thermostat", ["current_temperature": "70°F"]).statusGlyph == "◐")
    }

    @Test("unknown state falls back to empty circle")
    func fallback() {
        #expect(node("other", [:]).statusGlyph == "○")
    }
}

// MARK: - stateIsActive

@Suite("AccessoryNode.stateIsActive")
struct StateIsActiveTests {
    @Test("power on is active, off is not")
    func power() {
        #expect(node("lightbulb", ["power_state": "on"]).stateIsActive == true)
        #expect(node("lightbulb", ["power_state": "off"]).stateIsActive == false)
    }

    @Test("an unlocked lock counts as active (needs attention)")
    func lock() {
        #expect(node("lock", ["lock_current_state": "unlocked"]).stateIsActive == true)
        #expect(node("lock", ["lock_current_state": "locked"]).stateIsActive == false)
    }

    @Test("heating/cooling is active unless off")
    func hvac() {
        #expect(node("thermostat", ["current_heating_cooling_state": "heat"]).stateIsActive == true)
        #expect(node("thermostat", ["current_heating_cooling_state": "off"]).stateIsActive == false)
    }

    @Test("no recognised state is inactive")
    func none() {
        #expect(node("other", [:]).stateIsActive == false)
    }
}

// MARK: - toggleTarget (what Enter sends)

@Suite("AccessoryNode.toggleTarget")
struct ToggleTargetTests {
    @Test("power toggles to the opposite value")
    func power() {
        let on = node("lightbulb", ["power_state": "on"]).toggleTarget
        #expect(on?.characteristic == "power_state")
        #expect(on?.value == "off")

        let off = node("lightbulb", ["power_state": "off"]).toggleTarget
        #expect(off?.value == "on")
    }

    @Test("a locked lock toggles toward unlocked and vice versa")
    func lock() {
        let locked = node("lock", ["lock_current_state": "locked"]).toggleTarget
        #expect(locked?.characteristic == "lock_target_state")
        #expect(locked?.value == "unlocked")

        let unlocked = node("lock", ["lock_current_state": "unlocked"]).toggleTarget
        #expect(unlocked?.value == "locked")
    }

    @Test("blinds past halfway close, otherwise open")
    func position() {
        #expect(node("window_covering", ["current_position": "100"]).toggleTarget?.value == "0")
        #expect(node("window_covering", ["current_position": "20"]).toggleTarget?.value == "100")
        #expect(node("window_covering", ["current_position": "50"]).toggleTarget?.value == "100") // 50 is not > 50
    }

    @Test("sensors and thermostats have no defined toggle")
    func noToggle() {
        #expect(node("sensor", ["motion_detected": "yes"]).toggleTarget == nil)
        #expect(node("thermostat", ["current_temperature": "70°F"]).toggleTarget == nil)
        #expect(node("other", [:]).toggleTarget == nil)
    }
}

// MARK: - Ui.parseRooms (socket payload → room/accessory tree)

@Suite("Ui.parseRooms")
struct ParseRoomsTests {
    @Test("decodes rooms and nested accessories with state")
    func decodesTree() {
        let payload: [[String: Any]] = [
            [
                "id": "room-1",
                "name": "Living Room",
                "accessories": [
                    ["id": "a1", "name": "Lamp", "category": "lightbulb", "state": ["power_state": "On"]],
                    ["id": "a2", "name": "Blinds", "category": "window_covering", "state": ["current_position": "100"]],
                ],
            ],
        ]
        let rooms = Ui.parseRooms(payload)
        #expect(rooms.count == 1)
        #expect(rooms[0].name == "Living Room")
        #expect(rooms[0].accessories.count == 2)
        #expect(rooms[0].accessories[0].name == "Lamp")
        #expect(rooms[0].accessories[0].state["power_state"] == "On")
    }

    @Test("missing fields fall back to defaults without crashing")
    func defaults() {
        let rooms = Ui.parseRooms([["accessories": [["category": "other"]]]])
        #expect(rooms.count == 1)
        #expect(rooms[0].name == "Unknown")
        #expect(rooms[0].accessories[0].name == "Unknown")
        #expect(rooms[0].accessories[0].category == "other")
        #expect(rooms[0].accessories[0].state.isEmpty)
    }

    @Test("a room with no accessories array yields an empty accessory list")
    func emptyRoom() {
        let rooms = Ui.parseRooms([["id": "r", "name": "Empty"]])
        #expect(rooms[0].accessories.isEmpty)
    }

    @Test("an empty payload yields no rooms")
    func emptyPayload() {
        #expect(Ui.parseRooms([]).isEmpty)
    }
}
#endif
