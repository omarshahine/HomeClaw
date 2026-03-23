import HomeKit

/// Central HomeKit interface. Must run on @MainActor because HMHomeManager
/// requires main-thread delegate callbacks.
@MainActor
final class HomeKitManager: NSObject, Observable {
    static let shared = HomeKitManager()

    private let homeManager = HMHomeManager()
    private var homesReady = false
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

    private let cache = CharacteristicCache.shared
    private var isWarmingCache = false
    private var menuPushTask: Task<Void, Never>?

    private(set) var homes: [HMHome] = []

    override private init() {
        super.init()
        homeManager.delegate = self
    }

    // MARK: - Readiness

    /// Waits until HomeKit has delivered the initial set of homes.
    func waitForReady() async {
        if homesReady { return }
        await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }

    var isReady: Bool { homesReady }

    var totalAccessoryCount: Int {
        homes.reduce(0) { $0 + $1.accessories.count }
    }

    // MARK: - Homes

    func listHomes() async -> [[String: Any]] {
        await waitForReady()
        let activeHomes = filteredHomes(homeID: nil)
        let activeID = activeHomes.first?.uniqueIdentifier
        return homes.map { home in
            var dict = AccessoryModel.homeSummary(home)
            dict["is_selected"] = (home.uniqueIdentifier == activeID)
            return dict
        }
    }

    // MARK: - Rooms

    func listRooms(homeID: String? = nil) async -> [[String: Any]] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeID)
        var result: [[String: Any]] = []
        for home in targetHomes {
            for room in home.rooms {
                let filtered = filterAccessories(room.accessories)
                var dict = AccessoryModel.roomSummary(room)
                dict["accessory_count"] = filtered.count
                dict["accessories"] = filtered.map { accessory in
                    let id = accessory.uniqueIdentifier.uuidString
                    return AccessoryModel.accessorySummary(accessory, cachedState: cache.cachedState(for: id))
                }
                result.append(dict)
            }
        }
        if cache.isStale { Task { await warmCache() } }
        return result
    }

    // MARK: - Accessories

    func listAccessories(homeID: String? = nil, room: String? = nil) async -> [[String: Any]] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeID)
        var accessories: [HMAccessory] = []

        for home in targetHomes {
            if let roomName = room {
                let matchingRooms = home.rooms.filter {
                    $0.name.localizedCaseInsensitiveCompare(roomName) == .orderedSame
                }
                accessories.append(contentsOf: matchingRooms.flatMap(\.accessories))
            } else {
                accessories.append(contentsOf: home.accessories)
            }
        }

        let filtered = filterAccessories(accessories)

        // Pre-compute enrichment data (scoped to target homes)
        let allFiltered = targetHomes.flatMap { filterAccessories($0.accessories) }
        let displayNames = DeviceMap.computeDisplayNames(for: allFiltered)
        let roomZones = buildRoomZoneLookup(for: targetHomes)

        let result = filtered.map { accessory in
            let id = accessory.uniqueIdentifier
            let semanticType = DeviceMap.inferSemanticType(for: accessory)
            let zone: String? = accessory.room.flatMap { roomZones[$0.uniqueIdentifier] }
            return AccessoryModel.accessorySummary(
                accessory,
                cachedState: cache.cachedState(for: id.uuidString),
                zone: zone,
                displayName: displayNames[id],
                semanticType: semanticType.rawValue
            )
        }
        if cache.isStale { Task { await warmCache() } }
        return result
    }

    func getAccessory(id: String, homeID: String? = nil) async -> [String: Any]? {
        await waitForReady()
        guard let accessory = findAccessory(id: id, homeID: homeID) else { return nil }
        guard isAccessoryAllowed(accessory) else { return nil }
        await readAllValues(for: accessory)
        updateCacheFromAccessory(accessory)
        return AccessoryModel.accessoryDetail(accessory)
    }

    // MARK: - Control

    enum ControlError: Error, LocalizedError {
        case accessoryNotFound(String)
        case accessoryUnreachable(String)
        case characteristicNotFound(String)
        case characteristicNotWritable(String)
        case invalidValue(String)
        case writeFailed(String)
        case ambiguousCharacteristic(String, String)
        case homeNotFound(String)
        case roomNotFound(String)
        case zoneNotFound(String)

        var errorDescription: String? {
            switch self {
            case .accessoryNotFound(let id): "Accessory not found: \(id)"
            case .accessoryUnreachable(let name): "Accessory unreachable: \(name)"
            case .characteristicNotFound(let name): "Characteristic not found: \(name)"
            case .characteristicNotWritable(let name): "Characteristic not writable: \(name)"
            case .invalidValue(let detail): "Invalid value: \(detail)"
            case .writeFailed(let detail): "Write failed: \(detail)"
            case .ambiguousCharacteristic(let name, let options):
                "Ambiguous: '\(name)' exists on multiple services. Use service_type to disambiguate:\n\(options)"
            case .homeNotFound(let id): "Home not found: \(id)"
            case .roomNotFound(let id): "Room not found: \(id)"
            case .zoneNotFound(let id): "Zone not found: \(id)"
            }
        }
    }

    func controlAccessory(id: String, characteristic: String, value: String, homeID: String? = nil, serviceType: String? = nil, dryRun: Bool = false) async throws -> [String: Any] {
        await waitForReady()

        guard let accessory = findAccessory(id: id, homeID: homeID) else {
            throw ControlError.accessoryNotFound(id)
        }
        guard isAccessoryAllowed(accessory) else {
            throw ControlError.accessoryNotFound(id)
        }
        guard accessory.isReachable else {
            throw ControlError.accessoryUnreachable(accessory.name)
        }

        // Find the characteristic by human-readable name or UUID
        let hmCharacteristic: HMCharacteristic
        switch findCharacteristic(named: characteristic, on: accessory, serviceType: serviceType) {
        case .found(let c, _):
            hmCharacteristic = c
        case .notFound:
            throw ControlError.characteristicNotFound(characteristic)
        case .ambiguous(let matches):
            let options = matches.map { "  - service_type: \($0.serviceType) (service: \($0.service))" }.joined(separator: "\n")
            throw ControlError.ambiguousCharacteristic(characteristic, options)
        }

        // Check writability via properties
        let properties = hmCharacteristic.properties
        guard properties.contains(HMCharacteristicPropertyWritable) else {
            throw ControlError.characteristicNotWritable(characteristic)
        }

        // Parse value
        guard let parsedValue = CharacteristicMapper.parseValue(value, for: hmCharacteristic) else {
            throw ControlError.invalidValue("Cannot parse '\(value)' for \(characteristic)")
        }

        // Dry run: validate without writing
        if dryRun {
            let currentValue = hmCharacteristic.value.map { CharacteristicMapper.formatValue($0, for: hmCharacteristic.characteristicType) } ?? "unknown"
            var result: [String: Any] = [
                "dry_run": true,
                "valid": true,
                "name": accessory.name,
                "id": accessory.uniqueIdentifier.uuidString,
                "characteristic": characteristic,
                "current_value": currentValue,
                "new_value": value,
                "parsed_value": "\(parsedValue)",
            ]
            if let home = findHome(for: accessory) {
                result["home"] = home.name
            }
            return result
        }

        // Write
        do {
            try await hmCharacteristic.writeValue(parsedValue)
            let home = findHome(for: accessory)
            AppLogger.homekit.info("[\(home?.name ?? "?")] Set \(accessory.name).\(characteristic) = \(value)")
            HomeEventLogger.shared.logAccessoryControlled(
                accessoryID: accessory.uniqueIdentifier.uuidString,
                accessoryName: accessory.name,
                characteristic: characteristic,
                value: value,
                homeName: home?.name,
                homeID: home?.uniqueIdentifier.uuidString
            )
        } catch {
            throw ControlError.writeFailed("\(error.localizedDescription)")
        }

        // Read back current values, update cache, and return updated state
        await readInterestingValues(for: accessory)
        updateCacheFromAccessory(accessory)
        return AccessoryModel.accessorySummary(accessory)
    }

    // MARK: - Scenes

    func listScenes(homeID: String? = nil) async -> [[String: Any]] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeID)
        return targetHomes.flatMap { home in
            home.actionSets.map { actionSet in
                var dict = AccessoryModel.sceneSummary(actionSet)
                dict["home_name"] = home.name
                return dict
            }
        }
    }

    func triggerScene(id: String, homeID: String? = nil) async throws -> [String: Any] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeID)

        for home in targetHomes {
            if let actionSet = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == id }) {
                try await home.executeActionSet(actionSet)
                AppLogger.homekit.info("[\(home.name)] Triggered scene: \(actionSet.name)")
                HomeEventLogger.shared.logSceneTriggered(
                    sceneID: actionSet.uniqueIdentifier.uuidString,
                    sceneName: actionSet.name,
                    homeName: home.name,
                    homeID: home.uniqueIdentifier.uuidString
                )
                return AccessoryModel.sceneSummary(actionSet)
            }
        }

        // Try by name
        for home in targetHomes {
            if let actionSet = home.actionSets.first(where: {
                $0.name.localizedCaseInsensitiveCompare(id) == .orderedSame
            }) {
                try await home.executeActionSet(actionSet)
                AppLogger.homekit.info("[\(home.name)] Triggered scene: \(actionSet.name)")
                HomeEventLogger.shared.logSceneTriggered(
                    sceneID: actionSet.uniqueIdentifier.uuidString,
                    sceneName: actionSet.name,
                    homeName: home.name,
                    homeID: home.uniqueIdentifier.uuidString
                )
                return AccessoryModel.sceneSummary(actionSet)
            }
        }

        throw ControlError.accessoryNotFound("Scene not found: \(id)")
    }

    func getScene(id: String, homeID: String? = nil) async throws -> [String: Any] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeID)

        // Try by UUID first
        for home in targetHomes {
            if let actionSet = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == id }) {
                var detail = AccessoryModel.sceneDetail(actionSet)
                detail["home_name"] = home.name
                return detail
            }
        }

        // Try by name
        for home in targetHomes {
            if let actionSet = home.actionSets.first(where: {
                $0.name.localizedCaseInsensitiveCompare(id) == .orderedSame
            }) {
                var detail = AccessoryModel.sceneDetail(actionSet)
                detail["home_name"] = home.name
                return detail
            }
        }

        throw ControlError.accessoryNotFound("Scene not found: \(id)")
    }

    // MARK: - Scene Management

    func deleteScene(name: String, homeName: String? = nil, dryRun: Bool = false) async throws -> [String: Any] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeName)

        for home in targetHomes {
            if let actionSet = home.actionSets.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                if dryRun {
                    return [
                        "dry_run": true,
                        "valid": true,
                        "name": actionSet.name,
                        "home": home.name,
                        "action_count": actionSet.actions.count,
                    ]
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    home.removeActionSet(actionSet) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                AppLogger.homekit.info("[\(home.name)] Deleted scene: \(name)")
                return [
                    "deleted": true,
                    "name": actionSet.name,
                    "home": home.name,
                ]
            }
        }

        throw ControlError.accessoryNotFound("Scene not found: \(name)")
    }

    func assignRooms(
        homeName: String? = nil,
        assignments: [[String: String]],
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeName)
        guard let home = targetHomes.first else {
            throw ControlError.accessoryNotFound("No home found")
        }

        var assigned = 0
        var skipped = 0
        var notFound: [String] = []
        var details: [[String: String]] = []

        for entry in assignments {
            guard let accessoryName = entry["accessory"],
                  let targetRoomName = entry["room"]
            else {
                skipped += 1
                continue
            }

            guard let accessory = home.accessories.first(where: {
                $0.name.localizedCaseInsensitiveCompare(accessoryName) == .orderedSame
            }) else {
                notFound.append(accessoryName)
                continue
            }

            // Already in the correct room?
            if let currentRoom = accessory.room,
               currentRoom.name.localizedCaseInsensitiveCompare(targetRoomName) == .orderedSame
            {
                skipped += 1
                details.append([
                    "accessory": accessory.name,
                    "room": currentRoom.name,
                    "status": "already_assigned",
                ])
                continue
            }

            if dryRun {
                assigned += 1
                details.append([
                    "accessory": accessory.name,
                    "room": targetRoomName,
                    "status": "would_assign",
                ])
                continue
            }

            // Find or create target room
            let room: HMRoom
            if let existing = home.rooms.first(where: {
                $0.name.localizedCaseInsensitiveCompare(targetRoomName) == .orderedSame
            }) {
                room = existing
            } else {
                room = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HMRoom, Error>) in
                    home.addRoom(withName: targetRoomName) { newRoom, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let newRoom { continuation.resume(returning: newRoom) }
                        else { continuation.resume(throwing: ControlError.writeFailed("Failed to create room: \(targetRoomName)")) }
                    }
                }
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                home.assignAccessory(accessory, to: room) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }

            assigned += 1
            details.append([
                "accessory": accessory.name,
                "room": room.name,
                "status": "assigned",
            ])
        }

        return [
            "home": home.name,
            "dry_run": dryRun,
            "assigned": assigned,
            "skipped": skipped,
            "not_found": notFound,
            "details": details,
        ] as [String: Any]
    }

    func renameAccessory(
        id: String,
        newName: String,
        homeID: String? = nil,
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()
        let home = try resolveHome(homeID: homeID)
        guard let accessory = findAccessory(id: id, homeID: homeID) else {
            throw ControlError.accessoryNotFound(id)
        }

        let oldName = accessory.name
        if dryRun {
            return ["old_name": oldName, "new_name": newName, "home": home.name, "dry_run": true] as [String: Any]
        }

        try await homeKitAsync { accessory.updateName(newName, completionHandler: $0) }

        AppLogger.homekit.info("[\(home.name)] Renamed '\(oldName)' → '\(newName)'")
        return ["old_name": oldName, "new_name": newName, "home": home.name, "dry_run": false] as [String: Any]
    }

    // MARK: - Room Management

    func createRoom(
        name: String,
        homeID: String? = nil,
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()
        let home = try resolveHome(homeID: homeID)

        if dryRun {
            return ["dry_run": true, "name": name, "home": home.name] as [String: Any]
        }

        let room = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HMRoom, Error>) in
            home.addRoom(withName: name) { room, error in
                if let error { continuation.resume(throwing: error) }
                else if let room { continuation.resume(returning: room) }
                else { continuation.resume(throwing: ControlError.writeFailed("Failed to create room")) }
            }
        }

        AppLogger.homekit.info("[\(home.name)] Created room: \(name)")
        return ["name": room.name, "id": room.uniqueIdentifier.uuidString, "home": home.name, "dry_run": false] as [String: Any]
    }

    func renameRoom(
        roomID: String,
        newName: String,
        homeID: String? = nil,
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()
        let home = try resolveHome(homeID: homeID)
        guard let room = findRoom(id: roomID, in: home) else {
            throw ControlError.roomNotFound(roomID)
        }

        let oldName = room.name
        if dryRun {
            return ["dry_run": true, "old_name": oldName, "new_name": newName, "home": home.name] as [String: Any]
        }

        try await homeKitAsync { room.updateName(newName, completionHandler: $0) }

        AppLogger.homekit.info("[\(home.name)] Renamed room '\(oldName)' → '\(newName)'")
        return ["old_name": oldName, "new_name": newName, "id": room.uniqueIdentifier.uuidString, "home": home.name, "dry_run": false] as [String: Any]
    }

    func removeRoom(
        roomID: String,
        homeID: String? = nil,
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()
        let home = try resolveHome(homeID: homeID)
        guard let room = findRoom(id: roomID, in: home) else {
            throw ControlError.roomNotFound(roomID)
        }

        let roomName = room.name
        let accessoryCount = room.accessories.count
        if dryRun {
            return ["dry_run": true, "name": roomName, "accessory_count": accessoryCount, "home": home.name] as [String: Any]
        }

        try await homeKitAsync { home.removeRoom(room, completionHandler: $0) }

        AppLogger.homekit.info("[\(home.name)] Removed room: \(roomName) (\(accessoryCount) accessories)")
        return ["name": roomName, "accessory_count": accessoryCount, "home": home.name, "dry_run": false] as [String: Any]
    }

    // MARK: - Accessory Removal

    func removeAccessory(
        id: String,
        homeID: String? = nil,
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()
        let home = try resolveHome(homeID: homeID)
        guard let accessory = findAccessory(id: id, homeID: homeID) else {
            throw ControlError.accessoryNotFound(id)
        }

        let accessoryName = accessory.name
        let roomName = accessory.room?.name ?? "Default Room"
        if dryRun {
            return ["dry_run": true, "name": accessoryName, "room": roomName, "home": home.name] as [String: Any]
        }

        try await homeKitAsync { home.removeAccessory(accessory, completionHandler: $0) }

        AppLogger.homekit.info("[\(home.name)] Removed accessory: \(accessoryName) from \(roomName)")
        return ["name": accessoryName, "room": roomName, "home": home.name, "dry_run": false] as [String: Any]
    }

    // MARK: - Zone Management

    func createZone(
        name: String,
        homeID: String? = nil,
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()
        let home = try resolveHome(homeID: homeID)

        if dryRun {
            return ["dry_run": true, "name": name, "home": home.name] as [String: Any]
        }

        let zone = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HMZone, Error>) in
            home.addZone(withName: name) { zone, error in
                if let error { continuation.resume(throwing: error) }
                else if let zone { continuation.resume(returning: zone) }
                else { continuation.resume(throwing: ControlError.writeFailed("Failed to create zone")) }
            }
        }

        AppLogger.homekit.info("[\(home.name)] Created zone: \(name)")
        return ["name": zone.name, "id": zone.uniqueIdentifier.uuidString, "home": home.name, "dry_run": false] as [String: Any]
    }

    func removeZone(
        zoneID: String,
        homeID: String? = nil,
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()
        let home = try resolveHome(homeID: homeID)
        guard let zone = findZone(id: zoneID, in: home) else {
            throw ControlError.zoneNotFound(zoneID)
        }

        let zoneName = zone.name
        let roomCount = zone.rooms.count
        if dryRun {
            return ["dry_run": true, "name": zoneName, "room_count": roomCount, "home": home.name] as [String: Any]
        }

        try await homeKitAsync { home.removeZone(zone, completionHandler: $0) }

        AppLogger.homekit.info("[\(home.name)] Removed zone: \(zoneName) (\(roomCount) rooms)")
        return ["name": zoneName, "room_count": roomCount, "home": home.name, "dry_run": false] as [String: Any]
    }

    func addRoomToZone(
        roomID: String,
        zoneID: String,
        homeID: String? = nil,
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()
        let home = try resolveHome(homeID: homeID)
        guard let room = findRoom(id: roomID, in: home) else {
            throw ControlError.roomNotFound(roomID)
        }
        guard let zone = findZone(id: zoneID, in: home) else {
            throw ControlError.zoneNotFound(zoneID)
        }

        if dryRun {
            return ["dry_run": true, "room": room.name, "zone": zone.name, "home": home.name] as [String: Any]
        }

        try await homeKitAsync { zone.addRoom(room, completionHandler: $0) }

        AppLogger.homekit.info("[\(home.name)] Added room '\(room.name)' to zone '\(zone.name)'")
        return ["room": room.name, "zone": zone.name, "home": home.name, "dry_run": false] as [String: Any]
    }

    func removeRoomFromZone(
        roomID: String,
        zoneID: String,
        homeID: String? = nil,
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()
        let home = try resolveHome(homeID: homeID)
        guard let room = findRoom(id: roomID, in: home) else {
            throw ControlError.roomNotFound(roomID)
        }
        guard let zone = findZone(id: zoneID, in: home) else {
            throw ControlError.zoneNotFound(zoneID)
        }

        if dryRun {
            return ["dry_run": true, "room": room.name, "zone": zone.name, "home": home.name] as [String: Any]
        }

        try await homeKitAsync { zone.removeRoom(room, completionHandler: $0) }

        AppLogger.homekit.info("[\(home.name)] Removed room '\(room.name)' from zone '\(zone.name)'")
        return ["room": room.name, "zone": zone.name, "home": home.name, "dry_run": false] as [String: Any]
    }

    // MARK: - Private Helpers

    private func resolveHome(homeID: String?) throws -> HMHome {
        guard let home = filteredHomes(homeID: homeID).first else {
            throw ControlError.homeNotFound(homeID ?? "default")
        }
        return home
    }

    private func homeKitAsync(_ block: @escaping (@Sendable @escaping (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            block { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func findRoom(id: String, in home: HMHome) -> HMRoom? {
        if let room = home.rooms.first(where: { $0.uniqueIdentifier.uuidString == id }) {
            return room
        }
        return home.rooms.first(where: { $0.name.localizedCaseInsensitiveCompare(id) == .orderedSame })
    }

    private func findZone(id: String, in home: HMHome) -> HMZone? {
        if let zone = home.zones.first(where: { $0.uniqueIdentifier.uuidString == id }) {
            return zone
        }
        return home.zones.first(where: { $0.name.localizedCaseInsensitiveCompare(id) == .orderedSame })
    }

    func importScene(
        name: String,
        homeName: String? = nil,
        actions: [[String: String]],
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeName)
        guard let home = targetHomes.first else {
            throw ControlError.accessoryNotFound("No home found")
        }

        // Resolve each action to an accessory + characteristic + value
        var resolvedActions: [(accessory: HMAccessory, characteristic: HMCharacteristic, value: Any)] = []
        var warnings: [String] = []

        for action in actions {
            guard let accessoryName = action["accessory"],
                  let property = action["property"],
                  let valueStr = action["value"]
            else {
                warnings.append("Skipping action with missing fields: \(action)")
                continue
            }

            let roomName = action["room"]
            guard let accessory = findAccessoryByName(accessoryName, room: roomName, in: home) else {
                warnings.append("Accessory not found: \(accessoryName)" + (roomName.map { " in \($0)" } ?? ""))
                continue
            }

            guard let characteristic = findCharacteristicByDescription(on: accessory, property: property) else {
                warnings.append("Characteristic '\(property)' not found on \(accessory.name)")
                continue
            }

            guard let parsedValue = parseActionValue(valueStr, property: property) else {
                warnings.append("Cannot parse value '\(valueStr)' for \(property) on \(accessory.name)")
                continue
            }

            resolvedActions.append((accessory, characteristic, parsedValue))
        }

        if dryRun {
            return [
                "dry_run": true,
                "name": name,
                "home": home.name,
                "resolved_actions": resolvedActions.count,
                "warnings": warnings,
                "actions": resolvedActions.map { action in
                    [
                        "accessory": action.accessory.name,
                        "room": action.accessory.room?.name ?? "Default Room",
                        "characteristic": CharacteristicMapper.name(for: action.characteristic.characteristicType),
                        "value": "\(action.value)",
                    ] as [String: String]
                },
            ] as [String: Any]
        }

        // Create the action set
        let actionSet = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HMActionSet, Error>) in
            home.addActionSet(withName: name) { actionSet, error in
                if let error { continuation.resume(throwing: error) }
                else if let actionSet { continuation.resume(returning: actionSet) }
                else { continuation.resume(throwing: ControlError.writeFailed("Failed to create scene: \(name)")) }
            }
        }

        // Add each action
        var addedCount = 0
        for resolved in resolvedActions {
            let writeAction = HMCharacteristicWriteAction(
                characteristic: resolved.characteristic,
                targetValue: resolved.value as! NSCopying & NSObjectProtocol
            )
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                actionSet.addAction(writeAction) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            addedCount += 1
        }

        AppLogger.homekit.info("[\(home.name)] Imported scene '\(name)' with \(addedCount) action(s)")

        return [
            "created": true,
            "name": actionSet.name,
            "home": home.name,
            "action_count": addedCount,
            "warnings": warnings,
        ] as [String: Any]
    }

    // MARK: - Scene Management Helpers

    /// Find an accessory by name and optional room within a specific home.
    private func findAccessoryByName(_ name: String, room roomName: String?, in home: HMHome) -> HMAccessory? {
        for accessory in home.accessories {
            guard accessory.name.localizedCaseInsensitiveCompare(name) == .orderedSame else { continue }
            if let roomName {
                guard let room = accessory.room,
                      room.name.localizedCaseInsensitiveCompare(roomName) == .orderedSame
                else { continue }
            }
            return accessory
        }
        return nil
    }

    /// Find a characteristic on an accessory by its manufacturer description (human-readable name).
    private func findCharacteristicByDescription(on accessory: HMAccessory, property: String) -> HMCharacteristic? {
        for service in accessory.services {
            for characteristic in service.characteristics {
                let humanName = CharacteristicMapper.name(for: characteristic.characteristicType)
                if humanName.localizedCaseInsensitiveCompare(property) == .orderedSame {
                    return characteristic
                }
            }
        }
        return nil
    }

    /// Parse a human-readable action value back to an NSCopying-conforming type.
    /// Handles: ON/OFF, percentages (85%), temperatures (45.5deg), mireds (400mireds),
    /// lock states (Locked/Unlocked), and bare numbers.
    private func parseActionValue(_ raw: String, property: String) -> (NSCopying & NSObjectProtocol)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        // Boolean ON/OFF
        switch trimmed.uppercased() {
        case "ON", "TRUE", "1": return NSNumber(value: true)
        case "OFF", "FALSE", "0": return NSNumber(value: false)
        default: break
        }

        // Lock states
        switch trimmed.lowercased() {
        case "locked": return NSNumber(value: 1)
        case "unlocked": return NSNumber(value: 0)
        default: break
        }

        // Percentage: "85%"
        if trimmed.hasSuffix("%"), let n = Double(trimmed.dropLast()) {
            return NSNumber(value: n)
        }

        // Temperature: "45.5deg"
        if trimmed.lowercased().hasSuffix("deg"), let n = Double(trimmed.dropLast(3)) {
            return NSNumber(value: n)
        }

        // Color temperature in mireds: "400mireds"
        if trimmed.lowercased().hasSuffix("mireds"), let n = Double(trimmed.dropLast(6)) {
            return NSNumber(value: n)
        }

        // Bare integer
        if let n = Int(trimmed) {
            return NSNumber(value: n)
        }

        // Bare double
        if let n = Double(trimmed) {
            return NSNumber(value: n)
        }

        return nil
    }

    // MARK: - Search

    func searchAccessories(query: String, category: String? = nil, homeID: String? = nil) async -> [[String: Any]] {
        await waitForReady()
        let lowercasedQuery = query.lowercased()
        let targetHomes = filteredHomes(homeID: homeID)

        // Pre-compute enrichment data for display names and aliases
        let allFiltered = targetHomes.flatMap { filterAccessories($0.accessories) }
        let displayNames = DeviceMap.computeDisplayNames(for: allFiltered)

        var results: [HMAccessory] = []
        for home in targetHomes {
            for accessory in home.accessories {
                // Existing matches
                let nameMatch = accessory.name.lowercased().contains(lowercasedQuery)
                let roomMatch = accessory.room?.name.lowercased().contains(lowercasedQuery) ?? false
                let catName = CharacteristicMapper.inferredCategoryName(for: accessory)
                let catMatch = catName.contains(lowercasedQuery)

                // New matches
                let semanticType = DeviceMap.inferSemanticType(for: accessory)
                let semanticMatch = semanticType.rawValue.contains(lowercasedQuery)

                let displayName = displayNames[accessory.uniqueIdentifier] ?? accessory.name
                let displayNameMatch = displayName.lowercased().contains(lowercasedQuery)

                let manufacturerMatch =
                    accessory.manufacturer?.lowercased().contains(lowercasedQuery) ?? false

                let aliases = DeviceMap.generateAliases(
                    accessory: accessory, semanticType: semanticType,
                    category: catName, accessories: allFiltered
                )
                let aliasMatch = aliases.contains { $0.contains(lowercasedQuery) }

                if nameMatch || roomMatch || catMatch || semanticMatch || displayNameMatch
                    || manufacturerMatch || aliasMatch
                {
                    results.append(accessory)
                }
            }
        }

        // Filter by category if specified
        if let category {
            results = results.filter {
                CharacteristicMapper.inferredCategoryName(for: $0)
                    .localizedCaseInsensitiveCompare(category) == .orderedSame
            }
        }

        let filtered = filterAccessories(results)
        let roomZones = buildRoomZoneLookup(for: targetHomes)

        let output = filtered.map { accessory in
            let id = accessory.uniqueIdentifier
            let semanticType = DeviceMap.inferSemanticType(for: accessory)
            let zone: String? = accessory.room.flatMap { roomZones[$0.uniqueIdentifier] }
            return AccessoryModel.accessorySummary(
                accessory,
                cachedState: cache.cachedState(for: id.uuidString),
                zone: zone,
                displayName: displayNames[id],
                semanticType: semanticType.rawValue
            )
        }
        if cache.isStale { Task { await warmCache() } }
        return output
    }

    // MARK: - Device Map

    func deviceMap(homeID: String? = nil) async -> [String: Any] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeID)
        let result = DeviceMap.buildMap(homes: targetHomes, filter: filterAccessories, cache: cache)
        if cache.isStale { Task { await warmCache() } }
        return result
    }

    // MARK: - Unfiltered (Settings UI)

    /// Returns ALL accessories across all homes, ignoring filter settings.
    /// Used by the settings UI to populate the device checkbox list.
    func listAllAccessories() async -> [[String: Any]] {
        await waitForReady()
        return homes.flatMap { home in
            home.accessories.map { accessory in
                let id = accessory.uniqueIdentifier.uuidString
                var dict: [String: Any] = [
                    "id": id,
                    "name": accessory.name,
                    "category": CharacteristicMapper.inferredCategoryName(for: accessory),
                    "reachable": accessory.isReachable,
                    "home_name": home.name,
                    "home_id": home.uniqueIdentifier.uuidString,
                ]
                if let room = accessory.room {
                    dict["room"] = room.name
                }
                let homeDisplayName = AccessoryModel.computeHomeAppDisplayName(
                    for: accessory, roomName: accessory.room?.name)
                if homeDisplayName != accessory.name {
                    dict["home_display_name"] = homeDisplayName
                }
                if let cachedState = cache.cachedState(for: id), !cachedState.isEmpty {
                    dict["state"] = cachedState
                }
                return dict
            }
        }
    }

    // MARK: - Menu Data

    /// Builds a complete snapshot of the current home's rooms, accessories, and scenes
    /// for the menu bar. Reads only from the in-memory cache — no async I/O.
    func buildMenuData() -> [String: Any] {
        guard homesReady else { return ["ready": false] }

        let targetHomes = filteredHomes(homeID: nil)
        guard let selectedHome = targetHomes.first else {
            return ["ready": true, "selected_home": "", "homes": [], "scenes": [], "rooms": []]
        }

        let homesList: [[String: Any]] = homes.map { home in
            [
                "id": home.uniqueIdentifier.uuidString,
                "name": home.name,
                "is_selected": home.uniqueIdentifier == selectedHome.uniqueIdentifier,
            ]
        }

        let scenesList: [[String: Any]] = selectedHome.actionSets
            .map { AccessoryModel.sceneSummary($0) }
            .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }

        // Category priority: controllable items first, then status-only
        let categoryOrder: [String: Int] = [
            "lightbulb": 0, "switch": 1, "outlet": 2, "fan": 3,
            "air_purifier": 4, "valve": 5, "window_covering": 6,
            "thermostat": 10, "lock": 11, "door": 12, "garage_door": 13,
            "camera": 14, "doorbell": 15, "security_system": 16,
            "sensor": 20, "programmable_switch": 21,
        ]

        let roomsList: [[String: Any]] = selectedHome.rooms.compactMap { room in
            let filtered = filterAccessories(room.accessories)
            guard !filtered.isEmpty else { return nil }
            let accessories: [[String: Any]] = filtered
                .map { accessory in
                    let id = accessory.uniqueIdentifier.uuidString
                    return AccessoryModel.accessorySummary(
                        accessory, cachedState: cache.cachedState(for: id))
                }
                .sorted { a, b in
                    let catA = a["category"] as? String ?? "other"
                    let catB = b["category"] as? String ?? "other"
                    let orderA = categoryOrder[catA] ?? 50
                    let orderB = categoryOrder[catB] ?? 50
                    if orderA != orderB { return orderA < orderB }
                    return (a["name"] as? String ?? "") < (b["name"] as? String ?? "")
                }
            return [
                "name": room.name,
                "accessories": accessories,
            ]
        }
        .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }

        var data: [String: Any] = [
            "ready": true,
            "selected_home": selectedHome.name,
            "homes": homesList,
            "scenes": scenesList,
            "rooms": roomsList,
        ]

        let cb = WebhookCircuitBreaker.shared
        if cb.state != .closed {
            data["webhookCircuit"] = [
                "state": cb.state.rawValue,
                "softTripCount": cb.softTripCount,
                "remainingSeconds": cb.remainingCooldownSeconds,
                "totalDropped": cb.totalDroppedCount,
            ] as [String: Any]
        }

        return data
    }

    /// Debounced push of menu data via notification. Coalesces rapid updates
    /// (e.g., a scene triggering many accessories) into a single rebuild.
    func scheduleMenuDataPush() {
        menuPushTask?.cancel()
        menuPushTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(name: .homeKitMenuDataDidChange, object: nil)
        }
    }

    // MARK: - Cache

    /// Warms the cache by reading interesting values from all filtered accessories.
    /// Skips unreachable devices (retains their last known cached values).
    func warmCache() async {
        guard !isWarmingCache else { return }
        isWarmingCache = true
        defer { isWarmingCache = false }

        let start = Date()
        let allAccessories = homes.flatMap(\.accessories)
        let filtered = filterAccessories(allAccessories)
        let ids = filtered.map(\.uniqueIdentifier.uuidString)
        let currentHash = CharacteristicCache.computeDeviceHash(accessoryIDs: ids)

        // If device set changed, invalidate stale entries
        if !cache.deviceHashMatches(currentHash) {
            cache.invalidateValues()
            AppLogger.homekit.info("Device set changed, cache invalidated")
        }

        var warmedCount = 0
        for accessory in filtered {
            guard accessory.isReachable else { continue }

            var state: [String: String] = [:]
            for service in accessory.services {
                for characteristic in service.characteristics {
                    let name = CharacteristicMapper.name(for: characteristic.characteristicType)
                    if AccessoryModel.isInterestingState(name) {
                        try? await characteristic.readValue()
                        state[name] = CharacteristicMapper.formatValue(
                            characteristic.value, for: characteristic.characteristicType
                        )
                        // Subscribe to push notifications so the delegate callback fires
                        // when the value changes externally (e.g. Home app, physical switch).
                        // Without this, only security accessories (locks, doors) push updates.
                        if !characteristic.isNotificationEnabled {
                            try? await characteristic.enableNotification(true)
                        }
                    }
                }
            }
            if !state.isEmpty {
                cache.setValues(for: accessory.uniqueIdentifier.uuidString, state: state)
            }
            warmedCount += 1
            // Yield between accessories so other MainActor work (socket requests, UI) can run
            await Task.yield()
        }

        cache.markWarmed(deviceHash: currentHash)
        let elapsed = Date().timeIntervalSince(start)
        AppLogger.homekit.info(
            "Cache warmed: \(warmedCount)/\(filtered.count) accessories in \(String(format: "%.1f", elapsed))s"
        )
        scheduleMenuDataPush()
    }

    /// Extracts interesting state from an accessory after a live read and updates the cache.
    private func updateCacheFromAccessory(_ accessory: HMAccessory) {
        var state: [String: String] = [:]
        for service in accessory.services {
            for characteristic in service.characteristics {
                let name = CharacteristicMapper.name(for: characteristic.characteristicType)
                if AccessoryModel.isInterestingState(name) {
                    state[name] = CharacteristicMapper.formatValue(
                        characteristic.value, for: characteristic.characteristicType
                    )
                }
            }
        }
        if !state.isEmpty {
            cache.setValues(for: accessory.uniqueIdentifier.uuidString, state: state)
            cache.save()
        }
    }

    /// Force-refreshes the cache. Returns stats for the socket command.
    func refreshCache() async -> [String: Any] {
        await warmCache()
        return [
            "cached_accessories": cache.cachedAccessoryCount,
            "is_stale": cache.isStale,
            "last_warmed": cache.lastWarmedString as Any,
        ]
    }

    // MARK: - Value Reading

    /// Reads current values for "interesting" state characteristics on an accessory.
    /// Call before AccessoryModel.accessorySummary() so cached values are populated.
    private func readInterestingValues(for accessory: HMAccessory) async {
        guard accessory.isReachable else { return }
        for service in accessory.services {
            for characteristic in service.characteristics {
                let name = CharacteristicMapper.name(for: characteristic.characteristicType)
                if AccessoryModel.isInterestingState(name) {
                    try? await characteristic.readValue()
                }
            }
        }
    }

    /// Reads all readable characteristic values for a single accessory.
    /// Call before AccessoryModel.accessoryDetail() so cached values are populated.
    private func readAllValues(for accessory: HMAccessory) async {
        guard accessory.isReachable else { return }
        for service in accessory.services {
            for characteristic in service.characteristics {
                if characteristic.properties.contains(HMCharacteristicPropertyReadable) {
                    try? await characteristic.readValue()
                }
            }
        }
    }

    // MARK: - Private Helpers

    /// Builds a room UUID → zone name lookup table for enrichment.
    private func buildRoomZoneLookup(for targetHomes: [HMHome]) -> [UUID: String] {
        var roomZones: [UUID: String] = [:]
        for home in targetHomes {
            let zones = DeviceMap.resolveZones(for: home)
            for zone in zones {
                for room in zone.rooms {
                    roomZones[room.uniqueIdentifier] = zone.name
                }
            }
        }
        return roomZones
    }

    private func filterAccessories(_ accessories: [HMAccessory]) -> [HMAccessory] {
        let config = HomeClawConfig.shared
        guard config.filterMode == "allowlist",
              let allowed = config.allowedIDs
        else { return accessories }
        return accessories.filter { allowed.contains($0.uniqueIdentifier.uuidString) }
    }

    private func isAccessoryAllowed(_ accessory: HMAccessory) -> Bool {
        let config = HomeClawConfig.shared
        guard config.filterMode == "allowlist",
              let allowed = config.allowedIDs
        else { return true }
        return allowed.contains(accessory.uniqueIdentifier.uuidString)
    }

    private func filteredHomes(homeID: String?) -> [HMHome] {
        // Single home — no ambiguity
        if homes.count <= 1 { return homes }

        // Use explicit homeID if provided, otherwise fall back to configured default
        let effectiveID = homeID ?? HomeClawConfig.shared.defaultHomeID

        if let effectiveID {
            // Match by UUID first, then by name
            let byUUID = homes.filter { $0.uniqueIdentifier.uuidString == effectiveID }
            if !byUUID.isEmpty { return byUUID }

            let byName = homes.filter { $0.name.localizedCaseInsensitiveCompare(effectiveID) == .orderedSame }
            if !byName.isEmpty { return byName }
        }

        // No configured default or match failed — use primary home to avoid mixing
        if let primary = homes.first(where: \.isPrimary) {
            return [primary]
        }
        return [homes[0]]
    }

    /// Returns the home that contains the given accessory, or nil if not found.
    private func findHome(for accessory: HMAccessory) -> HMHome? {
        homes.first { $0.accessories.contains(where: { $0.uniqueIdentifier == accessory.uniqueIdentifier }) }
    }

    private func findAccessory(id: String, homeID: String? = nil) -> HMAccessory? {
        let targetHomes = filteredHomes(homeID: homeID)

        // Try UUID first (within target homes)
        for home in targetHomes {
            if let accessory = home.accessories.first(where: { $0.uniqueIdentifier.uuidString == id }) {
                return accessory
            }
        }
        // Try name match (within target homes)
        for home in targetHomes {
            if let accessory = home.accessories.first(where: {
                $0.name.localizedCaseInsensitiveCompare(id) == .orderedSame
            }) {
                return accessory
            }
        }
        return nil
    }

    /// Result of a characteristic lookup, which may be ambiguous.
    enum CharacteristicLookup {
        case found(HMCharacteristic, String)
        case ambiguous([(service: String, serviceType: String, characteristicName: String)])
        case notFound
    }

    /// Find a characteristic on an accessory by human-readable name or UUID.
    /// When `serviceType` is provided, only matches within that service.
    /// When nil and multiple services have a matching characteristic, returns `.ambiguous`.
    private func findCharacteristic(
        named name: String, on accessory: HMAccessory, serviceType: String? = nil
    ) -> CharacteristicLookup {
        var matches: [(characteristic: HMCharacteristic, humanName: String, serviceName: String, serviceType: String)] = []

        for service in accessory.services {
            if let filter = serviceType, service.serviceType.localizedCaseInsensitiveCompare(filter) != .orderedSame { continue }
            for characteristic in service.characteristics {
                let humanName = CharacteristicMapper.name(for: characteristic.characteristicType)
                if humanName.localizedCaseInsensitiveCompare(name) == .orderedSame
                    || characteristic.characteristicType == name
                {
                    matches.append((characteristic, humanName, service.name, service.serviceType))
                }
            }
        }

        switch matches.count {
        case 0:
            return .notFound
        case 1:
            return .found(matches[0].characteristic, matches[0].humanName)
        default:
            if serviceType != nil {
                // Filter was provided but still matched multiple in the same service — take first
                return .found(matches[0].characteristic, matches[0].humanName)
            }
            return .ambiguous(matches.map { (service: $0.serviceName, serviceType: $0.serviceType, characteristicName: $0.humanName) })
        }
    }
}

// MARK: - HMHomeManagerDelegate

extension HomeKitManager: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            homes = manager.homes
            let homeNames = manager.homes.map(\.name)
            AppLogger.homekit.info(
                "HomeKit updated: \(manager.homes.count) home(s) [\(homeNames.joined(separator: ", "))], \(self.totalAccessoryCount) accessory(ies)"
            )

            // Register as delegate for every accessory so we receive real-time value changes
            for home in manager.homes {
                for accessory in home.accessories {
                    accessory.delegate = self
                }
            }

            if !homesReady {
                homesReady = true
                for continuation in pendingContinuations {
                    continuation.resume()
                }
                pendingContinuations.removeAll()
            }

            // Warm cache after initial load and device set changes
            Task { await self.warmCache() }

            // Log the homes update event
            HomeEventLogger.shared.logHomesUpdated(
                homeCount: manager.homes.count,
                accessoryCount: self.totalAccessoryCount,
                homeNames: homeNames
            )

            // Notify macOSBridge (menu bar) of updated state
            NotificationCenter.default.post(
                name: .homeKitStatusDidChange,
                object: nil,
                userInfo: ["ready": self.homesReady, "homeNames": homeNames]
            )
            scheduleMenuDataPush()
        }
    }
}

extension Notification.Name {
    static let homeKitStatusDidChange = Notification.Name("HomeKitStatusDidChange")
    static let homeKitMenuDataDidChange = Notification.Name("HomeKitMenuDataDidChange")
    static let webhookCircuitStateDidChange = Notification.Name("WebhookCircuitStateDidChange")
}

// MARK: - HMAccessoryDelegate

extension HomeKitManager: HMAccessoryDelegate {
    /// Called when any characteristic value changes (e.g. a light turned off via the Home app).
    /// Updates the cache immediately so the next MCP/CLI query returns fresh state.
    nonisolated func accessory(
        _ accessory: HMAccessory,
        service: HMService,
        didUpdateValueFor characteristic: HMCharacteristic
    ) {
        Task { @MainActor in
            let name = CharacteristicMapper.name(for: characteristic.characteristicType)
            guard AccessoryModel.isInterestingState(name) else { return }

            let accessoryID = accessory.uniqueIdentifier.uuidString
            let value = CharacteristicMapper.formatValue(
                characteristic.value, for: characteristic.characteristicType
            )

            // Capture previous value before updating the cache
            let previousValue = cache.cachedState(for: accessoryID)?[name]

            // Update the single value in the cache
            var state = cache.cachedState(for: accessoryID) ?? [:]
            state[name] = value
            cache.setValues(for: accessoryID, state: state)
            cache.save()

            // Skip battery events from logging — they fire every 30-60s and flood the log.
            // Cache is already updated above so battery level is still queryable.
            let batteryChars: Set<String> = ["battery_level", "low_battery"]
            guard !batteryChars.contains(name) else {
                scheduleMenuDataPush()
                return
            }

            // During cache warmup, readValue() triggers this delegate for every characteristic.
            // Those are initial reads, not real state changes — skip logging and webhooks.
            guard !isWarmingCache else {
                scheduleMenuDataPush()
                return
            }

            // Skip unchanged values — HomeKit re-broadcasts cached state on hub
            // reconnection and sensor polling. Not real state transitions.
            if let previousValue, previousValue == value {
                AppLogger.homekit.debug("Skipped unchanged: \(accessory.name).\(name) = \(value)")
                scheduleMenuDataPush()
                return
            }

            // Look up which home this accessory belongs to
            let home = findHome(for: accessory)

            // Log the event — include the service category so trigger matching
            // can distinguish primary vs secondary characteristics (e.g. `power`
            // on a lightbulb service vs. a garage door opener service).
            let serviceCategory = CharacteristicMapper.serviceCategory(for: service.serviceType)
            HomeEventLogger.shared.logCharacteristicChange(
                accessoryID: accessoryID,
                accessoryName: accessory.name,
                room: accessory.room?.name,
                service: service.name,
                serviceType: serviceCategory,
                characteristic: name,
                value: value,
                previousValue: previousValue,
                homeName: home?.name,
                homeID: home?.uniqueIdentifier.uuidString
            )

            AppLogger.homekit.debug(
                "[\(home?.name ?? "?")] Live update: \(accessory.name).\(name) = \(value)"
            )
            scheduleMenuDataPush()
        }
    }
}
