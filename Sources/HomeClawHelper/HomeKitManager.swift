import HomeKit
import OSLog

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

        var errorDescription: String? {
            switch self {
            case .accessoryNotFound(let id): "Accessory not found: \(id)"
            case .accessoryUnreachable(let name): "Accessory unreachable: \(name)"
            case .characteristicNotFound(let name): "Characteristic not found: \(name)"
            case .characteristicNotWritable(let name): "Characteristic not writable: \(name)"
            case .invalidValue(let detail): "Invalid value: \(detail)"
            case .writeFailed(let detail): "Write failed: \(detail)"
            }
        }
    }

    func controlAccessory(id: String, characteristic: String, value: String, homeID: String? = nil) async throws -> [String: Any] {
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
        guard let (hmCharacteristic, _) = findCharacteristic(named: characteristic, on: accessory) else {
            throw ControlError.characteristicNotFound(characteristic)
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

        // Write
        do {
            try await hmCharacteristic.writeValue(parsedValue)
            HelperLogger.homekit.info("Set \(accessory.name).\(characteristic) = \(value)")
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
            home.actionSets.map { AccessoryModel.sceneSummary($0) }
        }
    }

    func triggerScene(id: String, homeID: String? = nil) async throws -> [String: Any] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeID)

        for home in targetHomes {
            if let actionSet = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == id }) {
                try await home.executeActionSet(actionSet)
                HelperLogger.homekit.info("Triggered scene: \(actionSet.name)")
                return AccessoryModel.sceneSummary(actionSet)
            }
        }

        // Try by name
        for home in targetHomes {
            if let actionSet = home.actionSets.first(where: {
                $0.name.localizedCaseInsensitiveCompare(id) == .orderedSame
            }) {
                try await home.executeActionSet(actionSet)
                HelperLogger.homekit.info("Triggered scene: \(actionSet.name)")
                return AccessoryModel.sceneSummary(actionSet)
            }
        }

        throw ControlError.accessoryNotFound("Scene not found: \(id)")
    }

    // MARK: - Room Assignment

    /// Assign accessories to rooms based on exported mappings.
    /// Matches accessories by name (case-insensitive) since UUIDs change after re-pairing.
    func assignRooms(
        homeName: String,
        assignments: [[String: Any]],
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()

        guard let home = homes.first(where: {
            $0.name.localizedCaseInsensitiveCompare(homeName) == .orderedSame
        }) else {
            throw ControlError.accessoryNotFound("Home not found: \(homeName)")
        }

        // Build room lookup (create rooms that don't exist)
        var roomLookup: [String: HMRoom] = [:]
        for room in home.rooms {
            roomLookup[room.name.lowercased()] = room
        }

        var assigned = 0
        var alreadyCorrect = 0
        var skipped = 0
        var notFound = 0
        var warnings: [[String: String]] = []
        var errors: [[String: String]] = []
        var roomsCreated: [String] = []
        var planned: [[String: String]] = []

        for assignment in assignments {
            guard let accName = assignment["accessory_name"] as? String,
                  let targetRoom = assignment["room"] as? String
            else {
                warnings.append(["type": "invalid", "detail": "Missing name or room in assignment"])
                skipped += 1
                continue
            }

            // Find the accessory by name
            guard let accessory = home.accessories.first(where: {
                $0.name.localizedCaseInsensitiveCompare(accName) == .orderedSame
            }) else {
                warnings.append([
                    "type": "accessory_not_found",
                    "accessory": accName,
                    "room": targetRoom,
                    "detail": "Accessory '\(accName)' not found in '\(homeName)'",
                ])
                notFound += 1
                continue
            }

            // Check if already in the correct room
            if let currentRoom = accessory.room,
               currentRoom.name.localizedCaseInsensitiveCompare(targetRoom) == .orderedSame {
                alreadyCorrect += 1
                continue
            }

            if dryRun {
                let currentRoomName = accessory.room?.name ?? "Default Room"
                planned.append([
                    "accessory": accName,
                    "from": currentRoomName,
                    "to": targetRoom,
                ])
                assigned += 1
                continue
            }

            // Find or create the target room
            var room = roomLookup[targetRoom.lowercased()]
            if room == nil {
                do {
                    room = try await withCheckedThrowingContinuation { cont in
                        home.addRoom(withName: targetRoom) { room, error in
                            if let error { cont.resume(throwing: error) }
                            else if let room { cont.resume(returning: room) }
                            else { cont.resume(throwing: ControlError.accessoryNotFound("Failed to create room '\(targetRoom)'")) }
                        }
                    }
                    roomLookup[targetRoom.lowercased()] = room
                    roomsCreated.append(targetRoom)
                    HelperLogger.homekit.info("Created room: \(targetRoom) in \(home.name)")
                } catch {
                    errors.append([
                        "accessory": accName,
                        "room": targetRoom,
                        "error": "Failed to create room: \(error.localizedDescription)",
                    ])
                    skipped += 1
                    continue
                }
            }

            // Assign the accessory to the room
            guard let targetRoomObj = room else {
                skipped += 1
                continue
            }

            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    home.assignAccessory(accessory, to: targetRoomObj) { error in
                        if let error { cont.resume(throwing: error) }
                        else { cont.resume() }
                    }
                }
                assigned += 1
                HelperLogger.homekit.info("Assigned '\(accName)' to '\(targetRoom)' in \(home.name)")
            } catch {
                errors.append([
                    "accessory": accName,
                    "room": targetRoom,
                    "error": error.localizedDescription,
                ])
                skipped += 1
            }
        }

        var result: [String: Any] = [
            "dry_run": dryRun,
            "home": homeName,
            "assigned": assigned,
            "already_correct": alreadyCorrect,
            "skipped": skipped,
            "not_found": notFound,
            "rooms_created": roomsCreated,
            "warnings": warnings,
            "errors": errors,
        ]
        if dryRun {
            result["planned"] = planned
        }
        return result
    }

    // MARK: - Scene Import

    /// Find an accessory by name and room (case-insensitive).
    private func findAccessory(name: String, room: String, in home: HMHome) -> HMAccessory? {
        return home.accessories.first { accessory in
            let nameMatch = accessory.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            let roomMatch = accessory.room?.name.localizedCaseInsensitiveCompare(room) == .orderedSame
            return nameMatch && roomMatch
        }
    }

    /// Find a characteristic on an accessory by its manufacturer description.
    private func findCharacteristic(on accessory: HMAccessory, property: String) -> HMCharacteristic? {
        for service in accessory.services {
            for characteristic in service.characteristics {
                if let desc = characteristic.metadata?.manufacturerDescription,
                   desc.localizedCaseInsensitiveCompare(property) == .orderedSame {
                    return characteristic
                }
            }
        }
        return nil
    }

    /// Parse a human-readable value string back to a HomeKit-compatible NSNumber.
    private func parseActionValue(_ valueStr: String, property: String) -> (NSCopying & NSObjectProtocol)? {
        let prop = property.lowercased()

        if prop.contains("power") {
            if valueStr == "ON" { return NSNumber(value: true) }
            if valueStr == "OFF" { return NSNumber(value: false) }
        }

        if prop.contains("lock") {
            if valueStr.contains("Secured") || valueStr.contains("Locked") { return NSNumber(value: 1) }
            if valueStr.contains("Unsecured") || valueStr.contains("Unlocked") { return NSNumber(value: 0) }
        }

        if valueStr.hasSuffix("%") {
            let numStr = String(valueStr.dropLast())
            if let intVal = Int(numStr) { return NSNumber(value: intVal) }
            if let dblVal = Double(numStr) { return NSNumber(value: dblVal) }
        }

        if valueStr.hasSuffix("°") {
            let numStr = String(valueStr.dropLast())
            if let dblVal = Double(numStr) { return NSNumber(value: dblVal) }
        }

        if valueStr.contains("mireds") {
                    let parts = valueStr.split(separator: " ")
                    if let first = parts.first {
                        if let intVal = Int(first) { return NSNumber(value: intVal) }
                        if let dblVal = Double(first) { return NSNumber(value: Int(dblVal)) }
                    }
                }

        if let intVal = Int(valueStr) { return NSNumber(value: intVal) }
        if let dblVal = Double(valueStr) { return NSNumber(value: dblVal) }

        HelperLogger.homekit.warning("Could not parse value '\(valueStr)' for property '\(property)'")
        return nil
    }

    /// Delete a scene by name.
    func deleteScene(name: String, homeName: String? = nil) async throws -> [String: Any] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: nil)

        for home in targetHomes {
            if let homeName, home.name.localizedCaseInsensitiveCompare(homeName) != .orderedSame {
                continue
            }
            if let actionSet = home.actionSets.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                let summary = AccessoryModel.sceneSummary(actionSet)
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                                    home.removeActionSet(actionSet) { error in
                                        if let error { cont.resume(throwing: error) }
                                        else { cont.resume() }
                                    }
                                }
                HelperLogger.homekit.info("Deleted scene: \(name) from \(home.name)")
                return [
                    "deleted": true,
                    "scene": summary,
                    "home": home.name,
                ] as [String: Any]
            }
        }

        throw ControlError.accessoryNotFound("Scene not found: \(name)")
    }

    /// Import a scene from exported action data. Matches accessories by name + room.
    func importScene(
        name: String,
        homeName: String,
        actions: [[String: Any]],
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()

        guard let home = homes.first(where: {
            $0.name.localizedCaseInsensitiveCompare(homeName) == .orderedSame
        }) else {
            throw ControlError.accessoryNotFound("Home not found: \(homeName)")
        }

        var resolvedActions: [(HMCharacteristic, NSCopying & NSObjectProtocol, [String: Any])] = []
        var warnings: [[String: String]] = []

        for actionData in actions {
            guard let accName = actionData["accessory_name"] as? String,
                  let room = actionData["room"] as? String,
                  let property = actionData["property"] as? String,
                  let valueStr = actionData["value"] as? String
            else {
                warnings.append(["type": "invalid_action", "detail": "Missing fields in action: \(actionData)"])
                continue
            }

            guard let accessory = findAccessory(name: accName, room: room, in: home) else {
                warnings.append([
                    "type": "accessory_not_found",
                    "accessory": accName,
                    "room": room,
                    "detail": "Could not find '\(accName)' in room '\(room)'",
                ])
                continue
            }

            guard let characteristic = findCharacteristic(on: accessory, property: property) else {
                warnings.append([
                    "type": "characteristic_not_found",
                    "accessory": accName,
                    "property": property,
                    "detail": "No '\(property)' characteristic on '\(accName)'",
                ])
                continue
            }

            guard let targetValue = parseActionValue(valueStr, property: property) else {
                warnings.append([
                    "type": "value_parse_error",
                    "accessory": accName,
                    "property": property,
                    "value": valueStr,
                    "detail": "Could not parse '\(valueStr)' for '\(property)'",
                ])
                continue
            }

            resolvedActions.append((characteristic, targetValue, actionData))
        }

        if dryRun {
            let planned = resolvedActions.map { (_, _, data) in data }
            return [
                "dry_run": true,
                "scene_name": name,
                "home": homeName,
                "actions_planned": planned.count,
                "actions_skipped": warnings.count,
                "planned": planned,
                "warnings": warnings,
            ] as [String: Any]
        }

        if home.actionSets.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            throw ControlError.accessoryNotFound(
                "Scene '\(name)' already exists in '\(homeName)'. Delete it first with delete-scene."
            )
        }

        let actionSet: HMActionSet = try await withCheckedThrowingContinuation { cont in
                    home.addActionSet(withName: name) { actionSet, error in
                        if let error { cont.resume(throwing: error) }
                        else if let actionSet { cont.resume(returning: actionSet) }
                        else { cont.resume(throwing: ControlError.accessoryNotFound("Failed to create action set")) }
                    }
                }
        HelperLogger.homekit.info("Created scene: \(name) in \(home.name)")

        var added = 0
        var actionErrors: [[String: String]] = []

        for (characteristic, targetValue, actionData) in resolvedActions {
            do {
                let action = HMCharacteristicWriteAction(
                    characteristic: characteristic,
                    targetValue: targetValue
                )
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                                    actionSet.addAction(action) { error in
                                        if let error { cont.resume(throwing: error) }
                                        else { cont.resume() }
                                    }
                                }
                added += 1
            } catch {
                let accName = actionData["accessory_name"] as? String ?? "?"
                let prop = actionData["property"] as? String ?? "?"
                actionErrors.append([
                    "accessory": accName,
                    "property": prop,
                    "error": error.localizedDescription,
                ])
                HelperLogger.homekit.error("Failed to add action \(accName)/\(prop): \(error.localizedDescription)")
            }
        }

        return [
            "dry_run": false,
            "scene_name": name,
            "home": homeName,
            "actions_added": added,
            "actions_skipped": warnings.count,
            "action_errors": actionErrors.count,
            "warnings": warnings,
            "errors": actionErrors,
            "scene": AccessoryModel.sceneSummary(actionSet),
        ] as [String: Any]
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
                var dict: [String: Any] = [
                    "id": accessory.uniqueIdentifier.uuidString,
                    "name": accessory.name,
                    "category": CharacteristicMapper.inferredCategoryName(for: accessory),
                    "home_name": home.name,
                    "home_id": home.uniqueIdentifier.uuidString,
                ]
                if let room = accessory.room {
                    dict["room"] = room.name
                }
                return dict
            }
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
            HelperLogger.homekit.info("Device set changed, cache invalidated")
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
        HelperLogger.homekit.info(
            "Cache warmed: \(warmedCount)/\(filtered.count) accessories in \(String(format: "%.1f", elapsed))s"
        )
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
        let config = HelperConfig.shared
        guard config.filterMode == "allowlist",
              let allowed = config.allowedIDs
        else { return accessories }
        return accessories.filter { allowed.contains($0.uniqueIdentifier.uuidString) }
    }

    private func isAccessoryAllowed(_ accessory: HMAccessory) -> Bool {
        let config = HelperConfig.shared
        guard config.filterMode == "allowlist",
              let allowed = config.allowedIDs
        else { return true }
        return allowed.contains(accessory.uniqueIdentifier.uuidString)
    }

    private func filteredHomes(homeID: String?) -> [HMHome] {
        // Single home — no ambiguity
        if homes.count <= 1 { return homes }

        // Use explicit homeID if provided, otherwise fall back to configured default
        let effectiveID = homeID ?? HelperConfig.shared.defaultHomeID

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

    private func findCharacteristic(
        named name: String, on accessory: HMAccessory
    ) -> (HMCharacteristic, String)? {
        for service in accessory.services {
            for characteristic in service.characteristics {
                let humanName = CharacteristicMapper.name(for: characteristic.characteristicType)
                if humanName.localizedCaseInsensitiveCompare(name) == .orderedSame
                    || characteristic.characteristicType == name
                {
                    return (characteristic, humanName)
                }
            }
        }
        return nil
    }
}

// MARK: - HMHomeManagerDelegate

extension HomeKitManager: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            homes = manager.homes
            HelperLogger.homekit.info(
                "HomeKit updated: \(manager.homes.count) home(s), \(self.totalAccessoryCount) accessory(ies)"
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
        }
    }
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

            // Update the single value in the cache
            var state = cache.cachedState(for: accessoryID) ?? [:]
            state[name] = value
            cache.setValues(for: accessoryID, state: state)
            cache.save()

            HelperLogger.homekit.debug(
                "Live update: \(accessory.name).\(name) = \(value)"
            )
        }
    }
}
