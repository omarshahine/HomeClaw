import Foundation

/// Synthetic HomeKit-shaped data used when `HomeKitManager.isDemoMode` is true.
///
/// Demo mode is gated by the `--ui-test-demo` launch arg or `HOMECLAW_DEMO=1` env
/// var. It exists for two reasons:
///   1. App Store / TestFlight screenshots that show realistic HomeClaw
///      functionality without leaking the developer's real homes.
///   2. End-to-end (L3) testing — the CLI / MCP server can be driven against the
///      running demo app over the socket and assert on deterministic responses,
///      with no HomeKit entitlement or iCloud HomeKit data required.
///
/// Dictionary shapes mirror what `AccessoryModel` produces from real HMHome data
/// and what the various `HomeKitManager` methods return — see `AccessoryModel`
/// and the corresponding `HomeKitManager.<method>` for the canonical shape each
/// helper here imitates. This is an in-memory, mutable model: create/rename/
/// remove/assign and automation/zone/scene CRUD all mutate the stored state, so
/// a sequence of demo-mode commands behaves like a real (if tiny) home. Call
/// `resetState()` to return to the seed so each test starts clean.
enum DemoFixtures {
    // Stable seed UUIDs so the same demo run produces deterministic IDs across launches.
    static let homeID = "00000000-0000-4000-8000-000000000001"
    static let livingRoomID = "00000000-0000-4000-8000-000000000010"
    static let kitchenID = "00000000-0000-4000-8000-000000000011"
    static let bedroomID = "00000000-0000-4000-8000-000000000012"

    static let homeName = "Demo Home"

    // MARK: - Mutable model state
    //
    // All mutable state is @MainActor because HomeKitManager (its only caller) is
    // @MainActor. Each collection is seeded from an immutable `seed*` constant and
    // reset by `resetState()`.

    /// Per-accessory characteristic state (e.g. `["power_state": "On"]`), keyed by
    /// accessory id. Mutated by `control` so demo toggles produce before/after state.
    @MainActor static var accessoryState: [String: [String: String]] = defaultAccessoryState

    @MainActor static var rooms: [Room] = seedRooms
    @MainActor static var accessories: [DemoAccessory] = seedAccessories
    @MainActor static var scenes: [DemoScene] = seedScenes
    @MainActor static var zones: [DemoZone] = []
    @MainActor static var automations: [DemoAutomation] = []

    /// Reset every mutable collection back to its seed. Call between tests so demo
    /// CRUD from one test doesn't leak into the next.
    @MainActor
    static func resetState() {
        accessoryState = defaultAccessoryState
        rooms = seedRooms
        accessories = seedAccessories
        scenes = seedScenes
        zones = []
        automations = []
    }

    // MARK: - Home / Rooms (read)

    @MainActor
    static func homeSummary(isSelected: Bool = true) -> [String: Any] {
        var dict: [String: Any] = [
            "id": homeID,
            "name": homeName,
            "is_primary": true,
            "room_count": rooms.count,
            "accessory_count": accessories.count,
            "scene_count": scenes.count,
        ]
        dict["is_selected"] = isSelected
        return dict
    }

    @MainActor
    static func roomSummaries() -> [[String: Any]] {
        let grouped = Dictionary(grouping: accessories) { $0.roomID }
        return rooms.map { room in
            let accessoriesInRoom = grouped[room.id] ?? []
            return [
                "id": room.id,
                "name": room.name,
                "accessory_count": accessoriesInRoom.count,
                "accessories": accessoriesInRoom.map { $0.summaryDict(roomName: room.name, state: state(for: $0.id)) },
            ]
        }
    }

    @MainActor
    static func accessorySummaries() -> [[String: Any]] {
        accessories.map { $0.summaryDict(roomName: roomName(for: $0.roomID), state: state(for: $0.id)) }
    }

    @MainActor
    static func allAccessoriesWithHome() -> [[String: Any]] {
        accessories.map { acc in
            var dict = acc.summaryDict(roomName: roomName(for: acc.roomID), state: state(for: acc.id))
            dict["home_name"] = homeName
            dict["home_id"] = homeID
            return dict
        }
    }

    @MainActor
    static func accessoryDetail(id: String) -> [String: Any]? {
        guard let acc = accessories.first(where: { $0.id == id }) else { return nil }
        return acc.detailDict(roomName: roomName(for: acc.roomID), state: state(for: acc.id))
    }

    // MARK: - Menu data

    @MainActor
    static func menuData() -> [String: Any] {
        let homesList: [[String: Any]] = [[
            "id": homeID,
            "name": homeName,
            "is_selected": true,
        ]]

        let scenesList: [[String: Any]] = scenes.map { scene in
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

        let grouped = Dictionary(grouping: accessories) { $0.roomID }
        let roomsList: [[String: Any]] = rooms.compactMap { room in
            let accs = grouped[room.id] ?? []
            guard !accs.isEmpty else { return nil }
            let summaries = accs
                .map { $0.summaryDict(roomName: room.name, state: state(for: $0.id)) }
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
    /// `controlAccessory`'s real return shape. Invalid ids surface as `nil`.
    @MainActor
    static func control(id: String, characteristic: String, value: String) -> [String: Any]? {
        guard let acc = accessories.first(where: { $0.id == id }) else { return nil }
        var current = state(for: id)
        current[characteristic] = value
        accessoryState[id] = current
        return acc.summaryDict(roomName: roomName(for: acc.roomID), state: current)
    }

    // MARK: - Search / device map (read derivations)

    /// Mirrors `searchAccessories`: case-insensitive substring match on name,
    /// optional category filter. Returns accessory summaries with home info.
    @MainActor
    static func searchAccessories(query: String, category: String?) -> [[String: Any]] {
        let q = query.lowercased()
        return accessories.filter { acc in
            let nameMatch = q.isEmpty || acc.name.lowercased().contains(q)
            let catMatch = category.map { acc.category == $0 } ?? true
            return nameMatch && catMatch
        }.map { acc in
            var dict = acc.summaryDict(roomName: roomName(for: acc.roomID), state: state(for: acc.id))
            dict["home_name"] = homeName
            return dict
        }
    }

    /// Mirrors `deviceMap`: home → rooms → accessories, with a flat count.
    @MainActor
    static func deviceMap() -> [String: Any] {
        let grouped = Dictionary(grouping: accessories) { $0.roomID }
        let roomMaps: [[String: Any]] = rooms.map { room in
            let accs = grouped[room.id] ?? []
            return [
                "room": room.name,
                "accessories": accs.map { acc -> [String: Any] in
                    [
                        "id": acc.id,
                        "name": acc.name,
                        "category": acc.category,
                        "manufacturer": acc.manufacturer,
                    ]
                },
            ]
        }
        return [
            "home": homeName,
            "accessory_count": accessories.count,
            "rooms": roomMaps,
        ]
    }

    // MARK: - Scenes (read + CRUD)

    @MainActor
    static func getScene(id: String) -> [String: Any]? {
        guard let scene = scenes.first(where: { $0.matches(id) }) else { return nil }
        return scene.detailDict()
    }

    /// Create a scene from an import payload. `actions` is an array of
    /// {accessory, characteristic/property, value}. Mirrors `importScene`.
    @MainActor
    static func importScene(name: String, actions: [[String: String]], dryRun: Bool) -> [String: Any] {
        if dryRun {
            return ["dry_run": true, "valid": true, "name": name, "home": homeName, "action_count": actions.count]
        }
        let scene = DemoScene(
            id: UUID().uuidString,
            name: name,
            actionCount: actions.count,
            rooms: []
        )
        scenes.append(scene)
        return ["created": true, "name": name, "id": scene.id, "home": homeName, "action_count": actions.count]
    }

    @MainActor
    static func updateScene(id: String, name: String?, actions: [[String: String]], dryRun: Bool) -> [String: Any]? {
        guard let idx = scenes.firstIndex(where: { $0.matches(id) }) else { return nil }
        let oldName = scenes[idx].name
        if dryRun {
            return ["dry_run": true, "valid": true, "name": oldName, "home": homeName, "action_count": actions.count]
        }
        if let name { scenes[idx].name = name }
        scenes[idx].actionCount = actions.count
        return ["updated": true, "name": scenes[idx].name, "id": scenes[idx].id, "home": homeName, "action_count": actions.count]
    }

    @MainActor
    static func deleteScene(name: String, dryRun: Bool) -> [String: Any]? {
        guard let idx = scenes.firstIndex(where: { $0.matches(name) }) else { return nil }
        let scene = scenes[idx]
        if dryRun {
            return ["dry_run": true, "valid": true, "name": scene.name, "home": homeName, "action_count": scene.actionCount]
        }
        scenes.remove(at: idx)
        return ["deleted": true, "name": scene.name, "home": homeName]
    }

    // MARK: - Rooms (CRUD)

    @MainActor
    static func createRoom(name: String, dryRun: Bool) -> [String: Any] {
        if dryRun { return ["dry_run": true, "name": name, "home": homeName] }
        let room = Room(id: UUID().uuidString, name: name)
        rooms.append(room)
        return ["name": room.name, "id": room.id, "home": homeName, "dry_run": false]
    }

    @MainActor
    static func renameRoom(id: String, newName: String, dryRun: Bool) -> [String: Any]? {
        guard let idx = rooms.firstIndex(where: { $0.matches(id) }) else { return nil }
        let oldName = rooms[idx].name
        if dryRun { return ["dry_run": true, "old_name": oldName, "new_name": newName, "home": homeName] }
        rooms[idx].name = newName
        return ["old_name": oldName, "new_name": newName, "id": rooms[idx].id, "home": homeName, "dry_run": false]
    }

    @MainActor
    static func removeRoom(id: String, dryRun: Bool) -> [String: Any]? {
        guard let idx = rooms.firstIndex(where: { $0.matches(id) }) else { return nil }
        let room = rooms[idx]
        let accessoryCount = accessories.filter { $0.roomID == room.id }.count
        if dryRun { return ["dry_run": true, "name": room.name, "accessory_count": accessoryCount, "home": homeName] }
        rooms.remove(at: idx)
        return ["name": room.name, "accessory_count": accessoryCount, "home": homeName, "dry_run": false]
    }

    @MainActor
    static func assignRooms(assignments: [[String: String]], dryRun: Bool) -> [String: Any] {
        var assigned = 0
        var skipped = 0
        var notFound: [String] = []
        var details: [[String: String]] = []

        for entry in assignments {
            guard let targetRoomName = entry["room"] else { skipped += 1; continue }
            let identifier = entry["uuid"] ?? entry["accessory"] ?? ""
            guard !identifier.isEmpty,
                  let accIdx = accessories.firstIndex(where: { $0.id == identifier || $0.name.lowercased() == identifier.lowercased() })
            else { notFound.append(identifier); continue }

            let currentRoom = roomName(for: accessories[accIdx].roomID)
            if currentRoom.lowercased() == targetRoomName.lowercased() {
                skipped += 1
                details.append(["accessory": accessories[accIdx].name, "room": currentRoom, "status": "already_assigned"])
                continue
            }
            if dryRun {
                assigned += 1
                details.append(["accessory": accessories[accIdx].name, "room": targetRoomName, "status": "would_assign"])
                continue
            }
            // Find or create the target room, then move the accessory.
            let room: Room
            if let existing = rooms.first(where: { $0.name.lowercased() == targetRoomName.lowercased() }) {
                room = existing
            } else {
                room = Room(id: UUID().uuidString, name: targetRoomName)
                rooms.append(room)
            }
            accessories[accIdx].roomID = room.id
            assigned += 1
            details.append(["accessory": accessories[accIdx].name, "room": room.name, "status": "assigned"])
        }

        return [
            "home": homeName,
            "dry_run": dryRun,
            "assigned": assigned,
            "skipped": skipped,
            "not_found": notFound,
            "details": details,
        ]
    }

    // MARK: - Accessory (rename / remove)

    @MainActor
    static func renameAccessory(id: String, newName: String, dryRun: Bool) -> [String: Any]? {
        guard let idx = accessories.firstIndex(where: { $0.id == id || $0.name.lowercased() == id.lowercased() }) else { return nil }
        let oldName = accessories[idx].name
        if dryRun { return ["old_name": oldName, "new_name": newName, "home": homeName, "dry_run": true] }
        accessories[idx].name = newName
        return ["old_name": oldName, "new_name": newName, "home": homeName, "services_renamed": 1, "dry_run": false]
    }

    @MainActor
    static func removeAccessory(id: String, dryRun: Bool) -> [String: Any]? {
        guard let idx = accessories.firstIndex(where: { $0.id == id || $0.name.lowercased() == id.lowercased() }) else { return nil }
        let acc = accessories[idx]
        let room = roomName(for: acc.roomID)
        if dryRun { return ["dry_run": true, "name": acc.name, "room": room, "home": homeName] }
        accessories.remove(at: idx)
        accessoryState[acc.id] = nil
        return ["name": acc.name, "room": room, "home": homeName, "dry_run": false]
    }

    // MARK: - Zones (CRUD)

    @MainActor
    static func createZone(name: String, dryRun: Bool) -> [String: Any] {
        if dryRun { return ["dry_run": true, "name": name, "home": homeName] }
        let zone = DemoZone(id: UUID().uuidString, name: name, roomIDs: [])
        zones.append(zone)
        return ["name": zone.name, "id": zone.id, "home": homeName, "dry_run": false]
    }

    @MainActor
    static func removeZone(id: String, dryRun: Bool) -> [String: Any]? {
        guard let idx = zones.firstIndex(where: { $0.matches(id) }) else { return nil }
        let zone = zones[idx]
        if dryRun { return ["dry_run": true, "name": zone.name, "room_count": zone.roomIDs.count, "home": homeName] }
        zones.remove(at: idx)
        return ["name": zone.name, "room_count": zone.roomIDs.count, "home": homeName, "dry_run": false]
    }

    @MainActor
    static func addRoomToZone(roomID: String, zoneID: String, dryRun: Bool) -> ZoneEditResult {
        guard let rIdx = rooms.firstIndex(where: { $0.matches(roomID) }) else { return .roomNotFound }
        guard let zIdx = zones.firstIndex(where: { $0.matches(zoneID) }) else { return .zoneNotFound }
        let roomDisplayName = rooms[rIdx].name
        let zoneDisplayName = zones[zIdx].name
        if dryRun { return .ok(["dry_run": true, "room": roomDisplayName, "zone": zoneDisplayName, "home": homeName]) }
        if !zones[zIdx].roomIDs.contains(rooms[rIdx].id) { zones[zIdx].roomIDs.append(rooms[rIdx].id) }
        return .ok(["room": roomDisplayName, "zone": zoneDisplayName, "home": homeName, "dry_run": false])
    }

    @MainActor
    static func removeRoomFromZone(roomID: String, zoneID: String, dryRun: Bool) -> ZoneEditResult {
        guard let rIdx = rooms.firstIndex(where: { $0.matches(roomID) }) else { return .roomNotFound }
        guard let zIdx = zones.firstIndex(where: { $0.matches(zoneID) }) else { return .zoneNotFound }
        let roomDisplayName = rooms[rIdx].name
        let zoneDisplayName = zones[zIdx].name
        if dryRun { return .ok(["dry_run": true, "room": roomDisplayName, "zone": zoneDisplayName, "home": homeName]) }
        zones[zIdx].roomIDs.removeAll { $0 == rooms[rIdx].id }
        return .ok(["room": roomDisplayName, "zone": zoneDisplayName, "home": homeName, "dry_run": false])
    }

    /// Two-failure-mode result so the manager can throw the right `ControlError`.
    enum ZoneEditResult {
        case ok([String: Any])
        case roomNotFound
        case zoneNotFound
    }

    // MARK: - Automations (list / get / CRUD)

    @MainActor
    static func listAutomations() -> [[String: Any]] {
        automations.map { $0.summaryDict() }
    }

    @MainActor
    static func getAutomation(id: String) -> [String: Any]? {
        automations.first(where: { $0.matches(id) })?.detailDict()
    }

    /// Create a button- or characteristic-triggered automation. Resolves the
    /// trigger accessory by id/name; returns nil if it doesn't exist (so the
    /// manager throws `accessoryNotFound`). `pressType` is the human label
    /// ("single"/"double"/"long"); `triggerType` is "button" or "characteristic".
    @MainActor
    static func createAutomation(
        name: String,
        accessoryID: String,
        triggerType: String,
        pressType: String?,
        serviceIndex: Int?,
        characteristic: String?,
        triggerValue: String?,
        sceneName: String?,
        actions: [[String: String]]?,
        conditions: [[String: String]],
        timeAfter: [String],
        timeBefore: [String],
        weekdays: [Int],
        weekdaysAutoFilled: Bool,
        durationSeconds: Int?,
        dryRun: Bool
    ) -> [String: Any]? {
        guard let acc = accessories.first(where: { $0.id == accessoryID || $0.name.lowercased() == accessoryID.lowercased() }) else {
            return nil
        }
        let inline = sceneName == nil
        let auto = DemoAutomation(
            id: UUID().uuidString,
            name: name,
            enabled: true,
            triggerType: triggerType,
            accessoryName: acc.name,
            pressType: pressType,
            serviceIndex: serviceIndex,
            characteristic: characteristic,
            triggerValue: triggerValue,
            time: nil,
            inlineActions: inline,
            actions: actions ?? [],
            sceneName: sceneName,
            conditions: conditions,
            timeAfter: timeAfter,
            timeBefore: timeBefore,
            weekdays: weekdays,
            weekdaysAutoFilled: weekdaysAutoFilled,
            durationSeconds: durationSeconds
        )
        if !dryRun { automations.append(auto) }
        return auto.createResult(dryRun: dryRun)
    }

    /// Create a time-of-day automation (clock or sunrise/sunset trigger).
    @MainActor
    static func createTimeAutomation(
        name: String,
        time: String,
        sceneName: String?,
        actions: [[String: String]]?,
        conditions: [[String: String]],
        timeAfter: [String],
        timeBefore: [String],
        weekdays: [Int],
        weekdaysAutoFilled: Bool,
        durationSeconds: Int?,
        dryRun: Bool
    ) -> [String: Any] {
        let inline = sceneName == nil
        let auto = DemoAutomation(
            id: UUID().uuidString,
            name: name,
            enabled: true,
            triggerType: "time",
            accessoryName: nil,
            pressType: nil,
            serviceIndex: nil,
            characteristic: nil,
            triggerValue: nil,
            time: time,
            inlineActions: inline,
            actions: actions ?? [],
            sceneName: sceneName,
            conditions: conditions,
            timeAfter: timeAfter,
            timeBefore: timeBefore,
            weekdays: weekdays,
            weekdaysAutoFilled: weekdaysAutoFilled,
            durationSeconds: durationSeconds
        )
        if !dryRun { automations.append(auto) }
        return auto.createResult(dryRun: dryRun)
    }

    @MainActor
    static func deleteAutomation(id: String, dryRun: Bool) -> [String: Any]? {
        guard let idx = automations.firstIndex(where: { $0.matches(id) }) else { return nil }
        let auto = automations[idx]
        let sceneCount = auto.attachedSceneNames.count
        if dryRun { return ["dry_run": true, "name": auto.name, "scene_count": sceneCount] }
        automations.remove(at: idx)
        return ["deleted": true, "name": auto.name]
    }

    @MainActor
    static func enableAutomation(id: String, enabled: Bool) -> [String: Any]? {
        guard let idx = automations.firstIndex(where: { $0.matches(id) }) else { return nil }
        automations[idx].enabled = enabled
        return ["name": automations[idx].name, "enabled": enabled]
    }

    /// Add/remove attached scenes in place (rewire). Mirrors `updateAutomationActionSets`.
    @MainActor
    static func updateAutomation(id: String, addScenes: [String], removeScenes: [String], dryRun: Bool) -> [String: Any]? {
        guard let idx = automations.firstIndex(where: { $0.matches(id) }) else { return nil }
        let before = automations[idx].attachedSceneNames
        var warnings: [String] = []
        let toAdd = addScenes.filter { name in
            if scenes.contains(where: { $0.matches(name) }) { return true }
            warnings.append("Scene not found: \(name)")
            return false
        }
        let toRemove = removeScenes
        if dryRun {
            return [
                "dry_run": true, "name": automations[idx].name,
                "before": before, "to_add": toAdd, "to_remove": toRemove, "warnings": warnings,
            ]
        }
        var attached = Set(before)
        toRemove.forEach { attached.remove($0) }
        toAdd.forEach { attached.insert($0) }
        let after = Array(attached).sorted()
        automations[idx].extraSceneNames = after
        return ["name": automations[idx].name, "before": before, "after": after, "warnings": warnings]
    }

    /// Append a characteristic condition to an automation's predicate. Mirrors
    /// `addAutomationCondition`. Resolves the condition accessory by id/name.
    @MainActor
    static func addAutomationCondition(
        id: String,
        accessoryID: String,
        room: String?,
        property: String,
        value: String,
        dryRun: Bool
    ) -> AutomationConditionResult {
        guard let aIdx = automations.firstIndex(where: { $0.matches(id) }) else { return .automationNotFound }
        guard let acc = accessories.first(where: { $0.id == accessoryID || $0.name.lowercased() == accessoryID.lowercased() }) else {
            return .accessoryNotFound
        }
        let countAfter = automations[aIdx].conditions.count + 1
        var result: [String: Any] = [
            "dry_run": dryRun,
            "name": automations[aIdx].name,
            "accessory": acc.name,
            "property": property,
            "value": value,
            "condition_count_after": countAfter,
        ]
        // Echo the room only when a name-based room hint was supplied (mirrors the
        // real method, which omits it on UUID lookups).
        if let room { result["room"] = room }
        if !dryRun {
            automations[aIdx].conditions.append(["accessory": acc.name, "property": property, "value": value])
        }
        return .ok(result)
    }

    enum AutomationConditionResult {
        case ok([String: Any])
        case automationNotFound
        case accessoryNotFound
    }

    // MARK: - Internal helpers

    @MainActor
    private static func state(for id: String) -> [String: String] {
        accessoryState[id] ?? [:]
    }

    @MainActor
    private static func roomName(for roomID: String) -> String {
        rooms.first { $0.id == roomID }?.name ?? "Default Room"
    }

    // MARK: - Model types

    struct Room {
        let id: String
        var name: String
        func matches(_ idOrName: String) -> Bool {
            id == idOrName || name.localizedCaseInsensitiveCompare(idOrName) == .orderedSame
        }
    }

    struct DemoZone {
        let id: String
        var name: String
        var roomIDs: [String]
        func matches(_ idOrName: String) -> Bool {
            id == idOrName || name.localizedCaseInsensitiveCompare(idOrName) == .orderedSame
        }
    }

    /// One accessory per (category, room) interesting combination. Names use
    /// generic descriptors — no brand names, no personal identifiers. `name` and
    /// `roomID` are mutable so rename / assign-room can update them in place.
    struct DemoAccessory {
        let id: String
        var name: String
        let category: String  // matches CharacteristicMapper.inferredCategoryName
        var roomID: String
        let manufacturer: String

        func summaryDict(roomName: String, state: [String: String]) -> [String: Any] {
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

        func detailDict(roomName: String, state: [String: String]) -> [String: Any] {
            var dict = summaryDict(roomName: roomName, state: state)
            dict["bridged"] = false
            dict["model"] = "Demo \(category.capitalized)"
            dict["firmware"] = "1.0"
            return dict
        }
    }

    struct DemoScene {
        let id: String
        var name: String
        var actionCount: Int
        var rooms: [String]

        func matches(_ idOrName: String) -> Bool {
            id == idOrName || name.localizedCaseInsensitiveCompare(idOrName) == .orderedSame
        }

        func detailDict() -> [String: Any] {
            [
                "id": id,
                "name": name,
                "home_name": homeName,
                "action_count": actionCount,
                "actions": [],
                "type": "user_defined",
                "rooms": rooms,
            ]
        }
    }

    /// In-memory automation record. Stores enough to render the list summary, the
    /// get detail, and the create-return shape that the CLI/MCP formatters read,
    /// without reproducing HMEventTrigger semantics.
    struct DemoAutomation {
        let id: String
        var name: String
        var enabled: Bool
        let triggerType: String   // "button" | "characteristic" | "time"
        var accessoryName: String?
        var pressType: String?
        var serviceIndex: Int?
        var characteristic: String?
        var triggerValue: String?
        var time: String?
        var inlineActions: Bool
        var actions: [[String: String]]
        var sceneName: String?
        var conditions: [[String: String]]
        var timeAfter: [String]
        var timeBefore: [String]
        var weekdays: [Int]
        var weekdaysAutoFilled: Bool
        var durationSeconds: Int?
        /// Scenes attached via `rewire` on top of the original target.
        var extraSceneNames: [String] = []

        func matches(_ idOrName: String) -> Bool {
            id == idOrName || name.localizedCaseInsensitiveCompare(idOrName) == .orderedSame
        }

        var attachedSceneNames: [String] {
            var names: [String] = []
            if inlineActions { names.append(name) }
            else if let sceneName { names.append(sceneName) }
            names.append(contentsOf: extraSceneNames)
            return Array(Set(names)).sorted()
        }

        private var eventSummary: String {
            switch triggerType {
            case "time": return "at \(time ?? "?")"
            case "characteristic": return "\(accessoryName ?? "?") \(characteristic ?? "?") = \(triggerValue ?? "?")"
            default: return "\(accessoryName ?? "?") \(pressType ?? "single") press"
            }
        }

        /// list shape — mirrors AccessoryModel.automationSummary.
        func summaryDict() -> [String: Any] {
            [
                "id": id,
                "name": name,
                "enabled": enabled,
                "home": homeName,
                "trigger_type": triggerType,
                "event_summary": eventSummary,
                "scenes": attachedSceneNames,
            ]
        }

        /// get shape — events[] + action_sets[].
        func detailDict() -> [String: Any] {
            var events: [[String: Any]] = []
            switch triggerType {
            case "time":
                events.append(["accessory": "Time", "press_type": time ?? "?"])
            case "characteristic":
                events.append(["accessory": accessoryName ?? "?", "press_type": "\(characteristic ?? "?") = \(triggerValue ?? "?")"])
            default:
                var e: [String: Any] = ["accessory": accessoryName ?? "?", "press_type": pressType ?? "single"]
                if let serviceIndex { e["service_index"] = serviceIndex }
                events.append(e)
            }
            let actionSets: [[String: Any]] = attachedSceneNames.map { sceneName in
                ["name": sceneName, "action_count": inlineActions ? actions.count : 1]
            }
            return [
                "id": id,
                "name": name,
                "enabled": enabled,
                "home": homeName,
                "trigger_type": triggerType,
                "events": events,
                "action_sets": actionSets,
            ]
        }

        /// create-return shape — mirrors HomeKitManager.createAutomation / createTimeAutomation.
        func createResult(dryRun: Bool) -> [String: Any] {
            var result: [String: Any] = [
                "id": id,
                "name": name,
                "home": homeName,
                "trigger_type": triggerType,
                "enabled": enabled,
                "dry_run": dryRun,
                "action_count": actions.count,
            ]
            if let accessoryName { result["accessory"] = accessoryName }
            if let time { result["time"] = time }
            switch triggerType {
            case "button":
                result["press_type"] = pressType ?? "single"
                if let serviceIndex { result["service_index"] = serviceIndex }
            case "characteristic":
                result["characteristic"] = characteristic
                result["trigger_value"] = triggerValue
            default:
                break
            }
            if inlineActions {
                result["inline_actions"] = true
                result["actions"] = actions
            } else if let sceneName {
                result["scene"] = sceneName
            }
            if !conditions.isEmpty { result["conditions"] = conditions }
            if !timeAfter.isEmpty { result["time_after"] = timeAfter }
            if !timeBefore.isEmpty { result["time_before"] = timeBefore }
            if !weekdays.isEmpty {
                result["weekdays"] = weekdays
                result["weekdays_auto_filled"] = weekdaysAutoFilled
            }
            if let durationSeconds { result["duration_seconds"] = durationSeconds }
            return result
        }
    }

    // MARK: - Seed data

    private static let seedRooms: [Room] = [
        Room(id: livingRoomID, name: "Living Room"),
        Room(id: kitchenID, name: "Kitchen"),
        Room(id: bedroomID, name: "Bedroom"),
    ]

    private static let seedAccessories: [DemoAccessory] = [
        // Living Room
        DemoAccessory(id: "00000000-0000-4000-8000-000000000100", name: "Floor Lamp", category: "lightbulb", roomID: livingRoomID, manufacturer: "Eve"),
        DemoAccessory(id: "00000000-0000-4000-8000-000000000101", name: "TV Light Strip", category: "lightbulb", roomID: livingRoomID, manufacturer: "Hue"),
        DemoAccessory(id: "00000000-0000-4000-8000-000000000102", name: "Thermostat", category: "thermostat", roomID: livingRoomID, manufacturer: "Ecobee"),
        DemoAccessory(id: "00000000-0000-4000-8000-000000000103", name: "Window Blinds", category: "window_covering", roomID: livingRoomID, manufacturer: "Lutron"),
        // Kitchen
        DemoAccessory(id: "00000000-0000-4000-8000-000000000110", name: "Counter Light", category: "lightbulb", roomID: kitchenID, manufacturer: "Hue"),
        DemoAccessory(id: "00000000-0000-4000-8000-000000000111", name: "Coffee Maker", category: "outlet", roomID: kitchenID, manufacturer: "Eve"),
        DemoAccessory(id: "00000000-0000-4000-8000-000000000112", name: "Motion Sensor", category: "sensor", roomID: kitchenID, manufacturer: "Aqara"),
        // Bedroom
        DemoAccessory(id: "00000000-0000-4000-8000-000000000120", name: "Bedside Lamp", category: "lightbulb", roomID: bedroomID, manufacturer: "Hue"),
        DemoAccessory(id: "00000000-0000-4000-8000-000000000121", name: "Ceiling Fan", category: "fan", roomID: bedroomID, manufacturer: "Lutron"),
        DemoAccessory(id: "00000000-0000-4000-8000-000000000122", name: "Door Lock", category: "lock", roomID: bedroomID, manufacturer: "Schlage"),
    ]

    /// Values match what `CharacteristicMapper.formatValue` produces against real
    /// HMHome data — pre-formatted units on temperatures, lower-case lock states.
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

    private static let seedScenes: [DemoScene] = [
        DemoScene(id: "00000000-0000-4000-8000-000000000200", name: "Good Morning", actionCount: 4, rooms: ["Bedroom", "Kitchen"]),
        DemoScene(id: "00000000-0000-4000-8000-000000000201", name: "Good Night", actionCount: 5, rooms: ["Bedroom", "Kitchen", "Living Room"]),
        DemoScene(id: "00000000-0000-4000-8000-000000000202", name: "Movie Time", actionCount: 3, rooms: ["Living Room"]),
    ]

    // MARK: - Counts / scene summaries (read)

    @MainActor
    static var sceneSummaries: [[String: Any]] {
        scenes.map { scene in
            [
                "id": scene.id,
                "name": scene.name,
                "action_count": scene.actionCount,
                "type": "user_defined",
                "rooms": scene.rooms,
            ]
        }
    }

    @MainActor
    static var demoAccessoryCount: Int { accessories.count }
    static var demoHomeCount: Int { 1 }
}
