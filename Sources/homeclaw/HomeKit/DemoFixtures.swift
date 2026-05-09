import Foundation

/// Synthetic HomeKit-shaped data used when `HomeKitManager.isDemoMode` is true.
///
/// Demo mode is gated by the `--ui-test-demo` launch arg or `HOMECLAW_DEMO=1` env
/// var. It exists so we can capture App Store / TestFlight screenshots that show
/// realistic HomeClaw functionality without leaking the developer's real homes.
///
/// Dictionary shapes mirror what `AccessoryModel` produces from real HMHome data —
/// see `AccessoryModel.homeSummary`, `roomSummary`, `accessorySummary`, and
/// `HomeKitManager.buildMenuData`. Values are mutable so demo control commands
/// can update state in-place (e.g., toggling a light).
enum DemoFixtures {
    // Stable UUIDs so the same demo run produces deterministic IDs across launches.
    static let homeID = "00000000-0000-4000-8000-000000000001"
    static let livingRoomID = "00000000-0000-4000-8000-000000000010"
    static let kitchenID = "00000000-0000-4000-8000-000000000011"
    static let bedroomID = "00000000-0000-4000-8000-000000000012"

    static let homeName = "Demo Home"

    /// Mutable accessory state so `controlAccessory` can update values for
    /// screenshots that need before/after framing. Keyed by accessory id.
    @MainActor
    static var accessoryState: [String: [String: String]] = defaultAccessoryState

    @MainActor
    static func resetState() { accessoryState = defaultAccessoryState }

    // MARK: - Home / Rooms

    static func homeSummary(isSelected: Bool = true) -> [String: Any] {
        var dict: [String: Any] = [
            "id": homeID,
            "name": homeName,
            "is_primary": true,
            "room_count": 3,
            "accessory_count": demoAccessories.count,
            "scene_count": demoScenes.count,
        ]
        dict["is_selected"] = isSelected
        return dict
    }

    @MainActor
    static func roomSummaries() -> [[String: Any]] {
        let grouped = Dictionary(grouping: demoAccessories) { $0.roomID }
        return rooms.map { room in
            let accessoriesInRoom = grouped[room.id] ?? []
            return [
                "id": room.id,
                "name": room.name,
                "accessory_count": accessoriesInRoom.count,
                "accessories": accessoriesInRoom.map { $0.summaryDict(state: state(for: $0.id)) },
            ]
        }
    }

    @MainActor
    static func accessorySummaries() -> [[String: Any]] {
        demoAccessories.map { $0.summaryDict(state: state(for: $0.id)) }
    }

    @MainActor
    static func allAccessoriesWithHome() -> [[String: Any]] {
        demoAccessories.map { acc in
            var dict = acc.summaryDict(state: state(for: acc.id))
            dict["home_name"] = homeName
            dict["home_id"] = homeID
            return dict
        }
    }

    @MainActor
    static func accessoryDetail(id: String) -> [String: Any]? {
        guard let acc = demoAccessories.first(where: { $0.id == id }) else { return nil }
        return acc.detailDict(state: state(for: acc.id))
    }

    // MARK: - Menu data

    @MainActor
    static func menuData() -> [String: Any] {
        let homesList: [[String: Any]] = [[
            "id": homeID,
            "name": homeName,
            "is_selected": true,
        ]]

        let scenesList: [[String: Any]] = demoScenes.map { scene in
            [
                "id": scene.id,
                "name": scene.name,
                "action_count": scene.actionCount,
                "type": "user_defined",
                "rooms": scene.rooms,
            ]
        }

        let categoryOrder: [String: Int] = [
            "lightbulb": 0, "switch": 1, "outlet": 2, "fan": 3,
            "air_purifier": 4, "valve": 5, "window_covering": 6,
            "thermostat": 10, "lock": 11, "door": 12, "garage_door": 13,
            "camera": 14, "doorbell": 15, "security_system": 16,
            "sensor": 20, "programmable_switch": 21,
        ]

        let grouped = Dictionary(grouping: demoAccessories) { $0.roomID }
        let roomsList: [[String: Any]] = rooms.compactMap { room in
            let accs = grouped[room.id] ?? []
            guard !accs.isEmpty else { return nil }
            let summaries = accs
                .map { $0.summaryDict(state: state(for: $0.id)) }
                .sorted { a, b in
                    let catA = a["category"] as? String ?? "other"
                    let catB = b["category"] as? String ?? "other"
                    let orderA = categoryOrder[catA] ?? 50
                    let orderB = categoryOrder[catB] ?? 50
                    if orderA != orderB { return orderA < orderB }
                    return (a["name"] as? String ?? "") < (b["name"] as? String ?? "")
                }
            return ["name": room.name, "accessories": summaries]
        }
        .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }

        return [
            "ready": true,
            "selected_home": homeName,
            "homes": homesList,
            "scenes": scenesList,
            "rooms": roomsList,
        ]
    }

    // MARK: - Control (mutates state)

    /// Updates `accessoryState[id]` and returns the new summary dict, matching
    /// `controlAccessory`'s real return shape. Throws nothing — invalid ids
    /// surface as `nil` to the caller.
    @MainActor
    static func control(id: String, characteristic: String, value: String) -> [String: Any]? {
        guard let acc = demoAccessories.first(where: { $0.id == id }) else { return nil }
        var current = state(for: id)
        current[characteristic] = value
        accessoryState[id] = current
        return acc.summaryDict(state: current)
    }

    @MainActor
    private static func state(for id: String) -> [String: String] {
        accessoryState[id] ?? [:]
    }

    // MARK: - Data

    private struct Room {
        let id: String
        let name: String
    }

    private static let rooms: [Room] = [
        Room(id: livingRoomID, name: "Living Room"),
        Room(id: kitchenID, name: "Kitchen"),
        Room(id: bedroomID, name: "Bedroom"),
    ]

    /// One accessory per (category, room) interesting combination. Names use
    /// generic descriptors — no brand names, no personal identifiers.
    private struct DemoAccessory {
        let id: String
        let name: String
        let category: String  // matches CharacteristicMapper.inferredCategoryName
        let roomID: String
        let manufacturer: String

        var roomName: String {
            DemoFixtures.rooms.first { $0.id == roomID }?.name ?? "Default Room"
        }

        func summaryDict(state: [String: String]) -> [String: Any] {
            var dict: [String: Any] = [
                "id": id,
                "name": name,
                "category": category,
                "reachable": true,
                "room": roomName,
                "manufacturer": manufacturer,
            ]
            if !state.isEmpty { dict["state"] = state }
            return dict
        }

        func detailDict(state: [String: String]) -> [String: Any] {
            var dict = summaryDict(state: state)
            dict["bridged"] = false
            dict["model"] = "Demo \(category.capitalized)"
            dict["firmware"] = "1.0"
            return dict
        }
    }

    private static let demoAccessories: [DemoAccessory] = [
        // Living Room
        DemoAccessory(
            id: "00000000-0000-4000-8000-000000000100",
            name: "Floor Lamp", category: "lightbulb",
            roomID: livingRoomID, manufacturer: "Eve"
        ),
        DemoAccessory(
            id: "00000000-0000-4000-8000-000000000101",
            name: "TV Light Strip", category: "lightbulb",
            roomID: livingRoomID, manufacturer: "Hue"
        ),
        DemoAccessory(
            id: "00000000-0000-4000-8000-000000000102",
            name: "Thermostat", category: "thermostat",
            roomID: livingRoomID, manufacturer: "Ecobee"
        ),
        DemoAccessory(
            id: "00000000-0000-4000-8000-000000000103",
            name: "Window Blinds", category: "window_covering",
            roomID: livingRoomID, manufacturer: "Lutron"
        ),

        // Kitchen
        DemoAccessory(
            id: "00000000-0000-4000-8000-000000000110",
            name: "Counter Light", category: "lightbulb",
            roomID: kitchenID, manufacturer: "Hue"
        ),
        DemoAccessory(
            id: "00000000-0000-4000-8000-000000000111",
            name: "Coffee Maker", category: "outlet",
            roomID: kitchenID, manufacturer: "Eve"
        ),
        DemoAccessory(
            id: "00000000-0000-4000-8000-000000000112",
            name: "Motion Sensor", category: "sensor",
            roomID: kitchenID, manufacturer: "Aqara"
        ),

        // Bedroom
        DemoAccessory(
            id: "00000000-0000-4000-8000-000000000120",
            name: "Bedside Lamp", category: "lightbulb",
            roomID: bedroomID, manufacturer: "Hue"
        ),
        DemoAccessory(
            id: "00000000-0000-4000-8000-000000000121",
            name: "Ceiling Fan", category: "fan",
            roomID: bedroomID, manufacturer: "Lutron"
        ),
        DemoAccessory(
            id: "00000000-0000-4000-8000-000000000122",
            name: "Door Lock", category: "lock",
            roomID: bedroomID, manufacturer: "Schlage"
        ),
    ]

    /// Values match what `CharacteristicMapper.formatValue` produces against
    /// real HMHome data — pre-formatted units on temperatures, lower-case
    /// lock states, etc. Anything else would have the TUI render demo data
    /// differently from production data.
    private static let defaultAccessoryState: [String: [String: String]] = [
        "00000000-0000-4000-8000-000000000100": ["power_state": "On", "brightness": "60"],
        "00000000-0000-4000-8000-000000000101": ["power_state": "On", "brightness": "40", "hue": "212"],
        "00000000-0000-4000-8000-000000000102": [
            "current_temperature": "70.5°F", "target_temperature": "72°F",
            "current_heating_cooling_state": "heat", "target_heating_cooling_state": "heat",
        ],
        "00000000-0000-4000-8000-000000000103": ["current_position": "100", "target_position": "100"],
        "00000000-0000-4000-8000-000000000110": ["power_state": "Off"],
        "00000000-0000-4000-8000-000000000111": ["power_state": "Off"],
        "00000000-0000-4000-8000-000000000112": ["motion_detected": "No"],
        "00000000-0000-4000-8000-000000000120": ["power_state": "Off"],
        "00000000-0000-4000-8000-000000000121": ["power_state": "On", "rotation_speed": "50"],
        "00000000-0000-4000-8000-000000000122": ["lock_current_state": "locked", "lock_target_state": "locked"],
    ]

    private struct DemoScene {
        let id: String
        let name: String
        let actionCount: Int
        let rooms: [String]
    }

    private static let demoScenes: [DemoScene] = [
        DemoScene(
            id: "00000000-0000-4000-8000-000000000200",
            name: "Good Morning", actionCount: 4,
            rooms: ["Bedroom", "Kitchen"]
        ),
        DemoScene(
            id: "00000000-0000-4000-8000-000000000201",
            name: "Good Night", actionCount: 5,
            rooms: ["Bedroom", "Kitchen", "Living Room"]
        ),
        DemoScene(
            id: "00000000-0000-4000-8000-000000000202",
            name: "Movie Time", actionCount: 3,
            rooms: ["Living Room"]
        ),
    ]

    static var sceneSummaries: [[String: Any]] {
        demoScenes.map { scene in
            [
                "id": scene.id,
                "name": scene.name,
                "action_count": scene.actionCount,
                "type": "user_defined",
                "rooms": scene.rooms,
            ]
        }
    }

    static var demoAccessoryCount: Int { demoAccessories.count }
    static var demoHomeCount: Int { 1 }
}
