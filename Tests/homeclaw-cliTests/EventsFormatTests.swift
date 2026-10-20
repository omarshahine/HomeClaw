import Foundation
import Testing
@testable import homeclaw_cli

@Suite("events formatting")
struct EventsFormatTests {
    @Test("reachability_change renders the transition, room and Matter node")
    func reachabilityWithNode() {
        let event: [String: Any] = [
            "type": "reachability_change",
            "reachable": false,
            "accessory": ["id": "A", "name": "B1", "room": "Kids", "matter_node_id": "000000000000002A"],
        ]
        #expect(Events.formatEvent(type: "reachability_change", event: event)
            == "B1 (Kids): became unreachable [matter node 000000000000002A]")
    }

    @Test("reachability_change without room or node id")
    func reachabilityPlain() {
        let event: [String: Any] = [
            "type": "reachability_change",
            "reachable": true,
            "accessory": ["id": "A", "name": "Plug", "room": NSNull()],
        ]
        #expect(Events.formatEvent(type: "reachability_change", event: event) == "Plug: became reachable")
    }

    @Test("existing characteristic_change rendering is unchanged")
    func characteristicChange() {
        let event: [String: Any] = [
            "accessory": ["name": "Lamp", "room": "Den"],
            "characteristic": "power", "value": "true", "previous_value": "false",
        ]
        #expect(Events.formatEvent(type: "characteristic_change", event: event) == "Lamp (Den): power = false → true")
    }
}
