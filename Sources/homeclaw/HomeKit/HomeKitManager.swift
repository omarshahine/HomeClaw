import HomeKit

// MARK: - Time Condition

/// A before/after sun-relative time predicate for automation triggers.
/// Composes via `HMEventTrigger.predicateForEvaluatingTrigger(occurringBefore/After:applyingOffset:)`.
///
/// Format: `<sun-event>[±<minutes>]` where sun-event is `sunrise` or `sunset` and the offset
/// is signed minutes (e.g. `sunset-30`, `sunrise+15`, `sunset`).
struct TimeCondition {
    enum Relation { case after, before }
    enum Event {
        case sunrise, sunset
        var significantEvent: String {
            self == .sunrise ? HMSignificantEvent.sunrise.rawValue : HMSignificantEvent.sunset.rawValue
        }
    }

    let relation: Relation
    let event: Event
    let offsetMinutes: Int   // positive = after the event, negative = before

    /// Reject offsets larger than 24h — almost certainly a typo (the user probably meant a
    /// `--days` filter). Smaller-than-24h but suspicious offsets (>720m / 12h) are allowed
    /// to keep the parser permissive; the CLI flag layer surfaces them in `--help`.
    static let maxOffsetMinutes = 1440

    func predicate() -> NSPredicate? {
        var offset: DateComponents? = nil
        if offsetMinutes != 0 {
            var dc = DateComponents()
            dc.minute = offsetMinutes
            offset = dc
        }
        // The string-form predicate APIs are marked deprecated in Catalyst 13.1+, but the
        // replacement (HMSignificantTimeEvent-taking variant) is not exposed to Swift —
        // only the DateComponents and HMPresenceEvent overloads bridge. Mirror the existing
        // weekday predicate construction (`occurringOn:`) which is in the same boat.
        switch relation {
        case .after:
            return HMEventTrigger.predicateForEvaluatingTrigger(
                occurringAfter: event.significantEvent,
                applyingOffset: offset
            )
        case .before:
            return HMEventTrigger.predicateForEvaluatingTrigger(
                occurringBefore: event.significantEvent,
                applyingOffset: offset
            )
        }
    }

    /// Parse a sun-relative time spec. Returns nil for malformed input;
    /// throws via the caller's `ValidationError` boundary.
    /// Accepts: `sunrise`, `sunset`, `sunrise+15`, `sunset-30`. Rejects: bare offsets,
    /// `noon`/`midnight`, missing-numeric offset (`sunset+`), unknown events.
    static func parse(_ raw: String, relation: Relation) -> TimeCondition? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        let event: Event
        var rest: String
        if s.hasPrefix("sunrise") {
            event = .sunrise
            rest = String(s.dropFirst("sunrise".count))
        } else if s.hasPrefix("sunset") {
            event = .sunset
            rest = String(s.dropFirst("sunset".count))
        } else {
            return nil
        }

        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.isEmpty {
            return TimeCondition(relation: relation, event: event, offsetMinutes: 0)
        }

        // Must start with + or -, followed by a positive integer (minutes).
        guard let sign = rest.first, sign == "+" || sign == "-" else { return nil }
        let numStr = String(rest.dropFirst())
        guard !numStr.isEmpty, let magnitude = Int(numStr), magnitude >= 0 else { return nil }
        if magnitude > maxOffsetMinutes { return nil }
        let offset = sign == "+" ? magnitude : -magnitude
        return TimeCondition(relation: relation, event: event, offsetMinutes: offset)
    }
}

/// Central HomeKit interface. Must run on @MainActor because HMHomeManager
/// requires main-thread delegate callbacks.
@MainActor
final class HomeKitManager: NSObject, Observable {
    static let shared = HomeKitManager()

    /// True when the app should bypass HomeKit and serve `DemoFixtures` data.
    /// Used by App Store screenshot capture so we never leak real home data.
    /// Gate: `--ui-test-demo` launch arg or `HOMECLAW_DEMO=1` env var.
    /// Evaluated once at first read and cached — `ProcessInfo` results don't
    /// change for the lifetime of the process.
    static let isDemoMode: Bool = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-test-demo") { return true }
        return ProcessInfo.processInfo.environment["HOMECLAW_DEMO"] == "1"
    }()

    private var homeManager: HMHomeManager?
    private var homesReady = false
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

    private let cache = CharacteristicCache.shared
    private var isWarmingCache = false
    private var menuPushTask: Task<Void, Never>?

    private(set) var homes: [HMHome] = []

    override private init() {
        super.init()
    }

    /// Create the HMHomeManager and begin HomeKit discovery.
    /// Call this after the first scene is connected so macOS can host
    /// the TCC consent dialog. On macOS 26.4+, creating HMHomeManager
    /// before a window exists causes a TCC privacy violation crash.
    func start() {
        guard homeManager == nil else { return }

        if Self.isDemoMode {
            AppLogger.homekit.info("Demo mode enabled — serving DemoFixtures, skipping HMHomeManager")
            homesReady = true
            for continuation in pendingContinuations { continuation.resume() }
            pendingContinuations.removeAll()
            NotificationCenter.default.post(
                name: .homeKitStatusDidChange,
                object: nil,
                userInfo: ["ready": true, "homeNames": [DemoFixtures.homeName]]
            )
            scheduleMenuDataPush()
            return
        }

        let manager = HMHomeManager()
        manager.delegate = self
        homeManager = manager
        AppLogger.homekit.info("HMHomeManager created, waiting for homes...")
    }

    // MARK: - Readiness

    /// Waits until HomeKit has delivered the initial set of homes.
    func waitForReady() async {
        if homesReady { return }
        if homeManager == nil {
            AppLogger.homekit.warning("waitForReady() called before start() — HomeKit not yet initialised")
        }
        await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }

    var isReady: Bool { homesReady }

    var totalAccessoryCount: Int {
        if Self.isDemoMode { return DemoFixtures.demoAccessoryCount }
        return homes.reduce(0) { $0 + $1.accessories.count }
    }

    /// Home count exposed to views. In demo mode the `homes` array is empty
    /// (HMHome objects can't be synthesized), so views must read this rather
    /// than `homes.count` directly. Routes through `DemoFixtures` to stay in
    /// sync with `listHomes()` if the fixture set ever grows past one home.
    var homeCount: Int {
        if Self.isDemoMode { return DemoFixtures.demoHomeCount }
        return homes.count
    }

    // MARK: - Homes

    func listHomes() async -> [[String: Any]] {
        await waitForReady()
        if Self.isDemoMode { return [DemoFixtures.homeSummary()] }
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
        if Self.isDemoMode { return DemoFixtures.roomSummaries() }
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
        if Self.isDemoMode {
            let all = DemoFixtures.accessorySummaries()
            guard let room else { return all }
            return all.filter { ($0["room"] as? String)?.localizedCaseInsensitiveCompare(room) == .orderedSame }
        }
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
        if Self.isDemoMode { return DemoFixtures.accessoryDetail(id: id) }
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
        case triggerNotFound(String)
        case sceneNotFound(String)
        case serviceNotFound(String)
        case invalidArgument(String)

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
            case .triggerNotFound(let id): "Automation not found: \(id)"
            case .sceneNotFound(let id): "Scene not found: \(id)"
            case .serviceNotFound(let detail): "Service not found: \(detail)"
            case .invalidArgument(let detail): "Invalid argument: \(detail)"
            }
        }
    }

    func controlAccessory(id: String, characteristic: String, value: String, homeID: String? = nil, serviceType: String? = nil, dryRun: Bool = false) async throws -> [String: Any] {
        await waitForReady()

        if Self.isDemoMode {
            guard let result = DemoFixtures.control(id: id, characteristic: characteristic, value: value) else {
                throw ControlError.accessoryNotFound(id)
            }
            scheduleMenuDataPush()
            return result
        }

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
        if Self.isDemoMode {
            return DemoFixtures.sceneSummaries.map { scene in
                var dict = scene
                dict["home_name"] = DemoFixtures.homeName
                return dict
            }
        }
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
        if Self.isDemoMode {
            guard let scene = DemoFixtures.sceneSummaries.first(where: {
                ($0["id"] as? String) == id
                    || ($0["name"] as? String)?.localizedCaseInsensitiveCompare(id) == .orderedSame
            }) else {
                throw ControlError.sceneNotFound(id)
            }
            return scene
        }
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
        let home = try resolveHome(homeID: homeName)

        var assigned = 0
        var skipped = 0
        var notFound: [String] = []
        var details: [[String: String]] = []

        for entry in assignments {
            guard let targetRoomName = entry["room"] else {
                skipped += 1
                continue
            }

            // Support UUID-based matching (preferred) or name-based (fallback).
            // UUID avoids ambiguity when multiple accessories share the same name
            // (e.g., fan + light services from a ceiling fan).
            let accessory: HMAccessory?
            let identifier: String
            if let uuidStr = entry["uuid"] {
                accessory = home.accessories.first(where: { $0.uniqueIdentifier.uuidString == uuidStr })
                identifier = uuidStr
            } else if let accessoryName = entry["accessory"] {
                accessory = home.accessories.first(where: {
                    $0.name.localizedCaseInsensitiveCompare(accessoryName) == .orderedSame
                })
                identifier = accessoryName
            } else {
                skipped += 1
                continue
            }

            guard let accessory else {
                notFound.append(identifier)
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
            if let existing = findRoom(id: targetRoomName, in: home) {
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

            try await homeKitAsync { home.assignAccessory(accessory, to: room, completionHandler: $0) }

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

    // MARK: - Automations (HMEventTrigger)

    func listAutomations(homeID: String? = nil) async -> [[String: Any]] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeID)
        var results: [[String: Any]] = []
        for home in targetHomes {
            // Iterate all triggers (event, timer, and any other HMTrigger subclass)
            // so HMTimerTrigger automations created via the iOS Home app are visible.
            for trigger in home.triggers {
                results.append(AccessoryModel.triggerSummary(trigger, homeName: home.name))
            }
        }
        return results
    }

    func getAutomation(id: String, homeID: String? = nil) async throws -> [String: Any] {
        await waitForReady()
        let home = try resolveHome(homeID: homeID)
        if let trigger = findEventTrigger(id: id, in: home) {
            return AccessoryModel.automationDetail(trigger, homeName: home.name, home: home)
        }
        if let timer = findTimerTrigger(id: id, in: home) {
            return AccessoryModel.timerTriggerDetail(timer, homeName: home.name)
        }
        throw ControlError.triggerNotFound(id)
    }

    func createAutomation(
        name: String,
        accessoryID: String,
        pressType: Int = 0,
        characteristic: String? = nil,
        triggerValue: String? = nil,
        sceneID: String? = nil,
        actions: [[String: String]]? = nil,
        serviceIndex: Int? = nil,
        weekdays: [Int] = [],
        conditions: [[String: String]] = [],
        timeConditions: [TimeCondition] = [],
        durationSeconds: Int? = nil,
        homeID: String? = nil,
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()
        let home = try resolveHome(homeID: homeID)

        guard let accessory = findAccessory(id: accessoryID, homeID: homeID) else {
            throw ControlError.accessoryNotFound(accessoryID)
        }

        // Resolve & validate condition predicates up-front so we fail before mutating HomeKit.
        // Each condition must reference a real accessory + characteristic; values must parse.
        // The resolved tuples are then used both for predicate construction (Step 1b) and for
        // structured echo back in the result dict.
        struct ResolvedCondition {
            let accessory: HMAccessory
            let characteristic: HMCharacteristic
            let property: String
            let value: NSCopying & NSObjectProtocol
            let rawValue: String
        }
        var resolvedConditions: [ResolvedCondition] = []
        for cond in conditions {
            guard let condAccessoryID = cond["accessory"],
                  let condProperty = cond["property"],
                  let condValueStr = cond["value"],
                  !condAccessoryID.isEmpty, !condProperty.isEmpty, !condValueStr.isEmpty
            else {
                throw ControlError.invalidArgument("Condition must have non-empty 'accessory', 'property', and 'value' keys")
            }
            // Match createAutomation's own resolution: UUID first, then case-insensitive name
            // (with optional `room` disambiguator if the caller supplied one).
            let condAccessory: HMAccessory
            if let found = home.accessories.first(where: { $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(condAccessoryID) == .orderedSame }) {
                condAccessory = found
            } else if let found = findAccessoryByName(condAccessoryID, room: cond["room"], in: home) {
                condAccessory = found
            } else {
                throw ControlError.accessoryNotFound(condAccessoryID)
            }
            guard let condChar = findCharacteristicByDescription(on: condAccessory, property: condProperty) else {
                throw ControlError.invalidArgument("Characteristic '\(condProperty)' not found on '\(condAccessory.name)' for --condition")
            }
            guard let parsed = parseActionValue(condValueStr, property: condProperty) else {
                throw ControlError.invalidArgument("Cannot parse condition value '\(condValueStr)' for '\(condProperty)'")
            }
            resolvedConditions.append(ResolvedCondition(
                accessory: condAccessory,
                characteristic: condChar,
                property: condProperty,
                value: parsed,
                rawValue: condValueStr
            ))
        }

        // iOS 15+ marks time-conditional automations without weekday gating as "unreliable".
        // Auto-fill all 7 days when --time-after / --time-before is set but --days is not,
        // so the automation actually fires. Surface this via `weekdays_auto_filled` so the
        // CLI/MCP caller knows we made a behavioural decision on their behalf.
        let weekdaysAutoFilled = !timeConditions.isEmpty && weekdays.isEmpty
        let effectiveWeekdays: [Int] = weekdaysAutoFilled ? [1, 2, 3, 4, 5, 6, 7] : weekdays

        // Echo conditions / time conditions back to the caller in a stable, structured shape.
        // Always set when input was provided so dry-run and success responses agree.
        let conditionsEcho: [[String: String]] = resolvedConditions.map {
            [
                "accessory": $0.accessory.name,
                "accessory_id": $0.accessory.uniqueIdentifier.uuidString,
                "property": $0.property,
                "value": $0.rawValue,
            ]
        }
        let timeAfterEcho: [String] = timeConditions.compactMap {
            guard $0.relation == .after else { return nil }
            let ev = $0.event == .sunrise ? "sunrise" : "sunset"
            if $0.offsetMinutes == 0 { return ev }
            return $0.offsetMinutes > 0 ? "\(ev)+\($0.offsetMinutes)" : "\(ev)\($0.offsetMinutes)"
        }
        let timeBeforeEcho: [String] = timeConditions.compactMap {
            guard $0.relation == .before else { return nil }
            let ev = $0.event == .sunrise ? "sunrise" : "sunset"
            if $0.offsetMinutes == 0 { return ev }
            return $0.offsetMinutes > 0 ? "\(ev)+\($0.offsetMinutes)" : "\(ev)\($0.offsetMinutes)"
        }
        // Closure used by both dry-run and success paths to attach predicate-related fields.
        // Keeping the shape identical between paths means callers/tests don't need to special-case.
        let attachPredicateFields: ([String: Any]) -> [String: Any] = { existing in
            var r = existing
            if !effectiveWeekdays.isEmpty { r["weekdays"] = effectiveWeekdays }
            if weekdaysAutoFilled { r["weekdays_auto_filled"] = true }
            if !conditionsEcho.isEmpty { r["conditions"] = conditionsEcho }
            if !timeAfterEcho.isEmpty { r["time_after"] = timeAfterEcho }
            if !timeBeforeEcho.isEmpty { r["time_before"] = timeBeforeEcho }
            return r
        }

        // Resolve the trigger characteristic and value based on trigger mode
        let triggerChar: HMCharacteristic
        let triggerNSValue: NSCopying
        let isButtonTrigger: Bool
        let triggerLabel: String

        if let characteristic {
            // Generic characteristic trigger (motion, contact, occupancy, etc.)
            triggerChar = try findTriggerCharacteristic(on: accessory, characteristicName: characteristic)
            guard let triggerValue else {
                throw ControlError.writeFailed("'trigger_value' is required when 'characteristic' is specified")
            }
            guard let parsed = CharacteristicMapper.parseValue(triggerValue, for: triggerChar),
                  let nsCopying = (parsed as AnyObject) as? NSCopying else {
                throw ControlError.writeFailed("Cannot parse trigger value '\(triggerValue)' for characteristic '\(characteristic)'")
            }
            triggerNSValue = nsCopying
            isButtonTrigger = false
            let formattedValue = CharacteristicMapper.formatValue(parsed, for: triggerChar.characteristicType)
            triggerLabel = "\(characteristic) = \(formattedValue)"
        } else {
            // Button press trigger (existing path)
            triggerChar = try findInputEventCharacteristic(on: accessory, serviceIndex: serviceIndex)
            triggerNSValue = NSNumber(value: pressType) as NSCopying
            isButtonTrigger = true
            triggerLabel = AccessoryModel.pressTypeName(pressType)
        }

        // Resolve the action set: either find an existing scene or create an inline one
        let actionSet: HMActionSet
        let isInlineActionSet: Bool

        if let actions, !actions.isEmpty {
            // Create an inline action set (like the Home app does for non-scene automations)
            let resolvedActions = try resolveActions(actions, in: home)

            if dryRun {
                var result: [String: Any] = [
                    "dry_run": true,
                    "inline_actions": true,
                    "name": name,
                    "home": home.name,
                    "accessory": accessory.name,
                    "trigger_type": isButtonTrigger ? "button" : "characteristic",
                    "action_count": resolvedActions.count,
                    "actions": resolvedActions.map { action in
                        [
                            "accessory": action.accessory.name,
                            "characteristic": CharacteristicMapper.name(for: action.characteristic.characteristicType),
                            "value": "\(action.value)",
                        ] as [String: String]
                    },
                ]
                if isButtonTrigger {
                    result["press_type"] = triggerLabel
                    if let serviceIndex { result["service_index"] = serviceIndex }
                } else {
                    result["characteristic"] = characteristic
                    result["trigger_value"] = triggerValue
                }
                if let durationSeconds { result["duration_seconds"] = durationSeconds }
                return attachPredicateFields(result)
            }

            // Action sets created via the public API are always visible in the Home app
            // (Apple uses a private API for hidden automation-only action sets).
            // Use the automation name so the scene tile is recognizable.
            let inlineSetName = name
            let newActionSet = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HMActionSet, Error>) in
                home.addActionSet(withName: inlineSetName) { actionSet, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let actionSet { continuation.resume(returning: actionSet) }
                    else { continuation.resume(throwing: ControlError.writeFailed("Failed to create action set")) }
                }
            }

            for resolved in resolvedActions {
                let writeAction = HMCharacteristicWriteAction(
                    characteristic: resolved.characteristic,
                    targetValue: resolved.value as! NSCopying & NSObjectProtocol
                )
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    newActionSet.addAction(writeAction) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            }

            actionSet = newActionSet
            isInlineActionSet = true
        } else if let sceneID {
            // Find an existing scene by UUID-then-name
            guard let existingSet = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == sceneID })
                    ?? home.actionSets.first(where: { $0.name.localizedCaseInsensitiveCompare(sceneID) == .orderedSame })
            else {
                throw ControlError.sceneNotFound(sceneID)
            }

            if dryRun {
                var result: [String: Any] = [
                    "dry_run": true,
                    "name": name,
                    "home": home.name,
                    "accessory": accessory.name,
                    "trigger_type": isButtonTrigger ? "button" : "characteristic",
                    "scene": existingSet.name,
                ]
                if isButtonTrigger {
                    result["press_type"] = triggerLabel
                    if let serviceIndex { result["service_index"] = serviceIndex }
                } else {
                    result["characteristic"] = characteristic
                    result["trigger_value"] = triggerValue
                }
                if let durationSeconds { result["duration_seconds"] = durationSeconds }
                return attachPredicateFields(result)
            }

            actionSet = existingSet
            isInlineActionSet = false
        } else {
            throw ControlError.writeFailed("Either 'scene_id' or 'actions' must be provided")
        }

        // Create the event trigger
        let event = HMCharacteristicEvent(
            characteristic: triggerChar,
            triggerValue: triggerNSValue
        )
        let trigger = HMEventTrigger(
            name: name,
            events: [event],
            end: nil,
            recurrences: nil,
            predicate: nil
        )

        // Step 1: Add trigger to home
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.addTrigger(trigger) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }

        // Step 1b: Build the combined trigger predicate from weekdays + conditions +
        // time conditions and apply it in a single `updatePredicate` call.
        //
        // Only the LAST `updatePredicate` call sticks, so all three predicate kinds must be
        // composed together. The structure is one outer AND:
        //
        //   AND(
        //     existing-trigger-predicate,                  // currently always nil at this point
        //     OR(weekday=1, weekday=2, ...),               // from --days / auto-fill
        //     characteristic-condition-1,                  // from each --condition
        //     characteristic-condition-2,
        //     time-condition-1,                            // from each --time-after / --time-before
        //     ...
        //   )
        //
        // If only one of these is present, we either skip the call entirely (none) or pass the
        // single predicate directly (no compound wrapper). Failure rolls back the orphan trigger
        // (and inline action set if we created one), mirroring the action-set-link rollback path.
        var subpredicates: [NSPredicate] = []
        if let existing = trigger.predicate { subpredicates.append(existing) }
        if !effectiveWeekdays.isEmpty {
            let dayPredicates: [NSPredicate] = effectiveWeekdays.map { weekday in
                var dc = DateComponents()
                dc.weekday = weekday
                return HMEventTrigger.predicateForEvaluatingTrigger(occurringOn: dc)
            }
            subpredicates.append(
                dayPredicates.count == 1
                    ? dayPredicates[0]
                    : NSCompoundPredicate(orPredicateWithSubpredicates: dayPredicates)
            )
        }
        for cond in resolvedConditions {
            subpredicates.append(
                HMEventTrigger.predicateForEvaluatingTrigger(
                    cond.characteristic,
                    relatedBy: .equalTo,
                    toValue: cond.value
                )
            )
        }
        for tc in timeConditions {
            if let p = tc.predicate() { subpredicates.append(p) }
        }
        if !subpredicates.isEmpty {
            let combinedPredicate: NSPredicate = subpredicates.count == 1
                ? subpredicates[0]
                : NSCompoundPredicate(andPredicateWithSubpredicates: subpredicates)
            do {
                try await homeKitAsync { trigger.updatePredicate(combinedPredicate, completionHandler: $0) }
            } catch {
                // Cleanup on predicate failure: remove the orphaned trigger AND the inline
                // action set if we created one. (The action set exists in `home.actionSets`
                // from Step 1's `addActionSet` call even though it's not yet linked to the
                // trigger — without this removal it would persist as an orphaned scene tile.)
                if isInlineActionSet {
                    try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        home.removeActionSet(actionSet) { err in
                            if let err { continuation.resume(throwing: err) }
                            else { continuation.resume() }
                        }
                    }
                }
                try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    home.removeTrigger(trigger) { err in
                        if let err { continuation.resume(throwing: err) }
                        else { continuation.resume() }
                    }
                }
                throw error
            }
        }

        // Step 1c: Attach an HMDurationEvent end-event so HomeKit reverts the
        // trigger's actions after N seconds (e.g. motion-triggered light auto-off).
        // Mirrors the predicate cleanup pattern: on failure, tear down the orphan
        // trigger (and inline action set if we created one) before rethrowing.
        if let durationSeconds {
            do {
                try await applyDuration(seconds: durationSeconds, to: trigger)
            } catch {
                if isInlineActionSet {
                    try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        home.removeActionSet(actionSet) { err in
                            if let err { continuation.resume(throwing: err) }
                            else { continuation.resume() }
                        }
                    }
                }
                try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    home.removeTrigger(trigger) { err in
                        if let err { continuation.resume(throwing: err) }
                        else { continuation.resume() }
                    }
                }
                throw error
            }
        }

        // Step 2: Link the action set
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                trigger.addActionSet(actionSet) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch {
            // Cleanup: remove the orphaned trigger (and inline action set if we created one)
            if isInlineActionSet {
                try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    home.removeActionSet(actionSet) { err in
                        if let err { continuation.resume(throwing: err) }
                        else { continuation.resume() }
                    }
                }
            }
            try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                home.removeTrigger(trigger) { err in
                    if let err { continuation.resume(throwing: err) }
                    else { continuation.resume() }
                }
            }
            throw error
        }

        // Step 3: Enable the trigger
        do {
            try await homeKitAsync { trigger.enable(true, completionHandler: $0) }
        } catch {
            // Cleanup on enable failure
            if isInlineActionSet {
                try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    home.removeActionSet(actionSet) { err in
                        if let err { continuation.resume(throwing: err) }
                        else { continuation.resume() }
                    }
                }
            }
            try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                home.removeTrigger(trigger) { err in
                    if let err { continuation.resume(throwing: err) }
                    else { continuation.resume() }
                }
            }
            throw error
        }

        let actionLabel = isInlineActionSet ? "\(actionSet.actions.count) inline action(s)" : actionSet.name
        AppLogger.homekit.info("[\(home.name)] Created automation '\(name)': \(accessory.name) \(triggerLabel) → \(actionLabel)")
        var result: [String: Any] = [
            "id": trigger.uniqueIdentifier.uuidString,
            "name": name,
            "home": home.name,
            "accessory": accessory.name,
            "trigger_type": isButtonTrigger ? "button" : "characteristic",
            "enabled": true,
            "dry_run": false,
            "action_count": actionSet.actions.count,
        ]
        if isButtonTrigger {
            result["press_type"] = triggerLabel
            if let serviceIndex { result["service_index"] = serviceIndex }
        } else {
            result["characteristic"] = characteristic
            result["trigger_value"] = triggerValue
        }
        if isInlineActionSet {
            result["inline_actions"] = true
        } else {
            result["scene"] = actionSet.name
        }
        if let durationSeconds {
            result["duration_seconds"] = durationSeconds
        }
        return attachPredicateFields(result)
    }

    /// Add an HMDurationEvent to the trigger's `endEvents` so HomeKit reverts
    /// any characteristics turned on by the trigger after the given duration.
    /// Used by `--duration N` on `automations create` to implement auto-off
    /// for motion-triggered lights and similar patterns.
    private func applyDuration(seconds: Int, to trigger: HMEventTrigger) async throws {
        let durationEvent = HMDurationEvent(duration: TimeInterval(seconds))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.updateEndEvents([durationEvent]) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    /// Resolve action definitions to HomeKit accessory/characteristic/value tuples.
    /// The `accessory` field accepts UUIDs (preferred) or names.
    private func resolveActions(
        _ actions: [[String: String]],
        in home: HMHome
    ) throws -> [(accessory: HMAccessory, characteristic: HMCharacteristic, value: Any)] {
        var resolved: [(accessory: HMAccessory, characteristic: HMCharacteristic, value: Any)] = []

        for action in actions {
            guard let accessoryID = action["accessory"],
                  let property = action["property"],
                  let valueStr = action["value"]
            else {
                throw ControlError.writeFailed("Action missing required fields (accessory, property, value): \(action)")
            }

            // Try UUID first, then name with optional room disambiguator
            let accessory: HMAccessory
            if let found = home.accessories.first(where: { $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(accessoryID) == .orderedSame }) {
                accessory = found
            } else {
                let roomName = action["room"]
                guard let found = findAccessoryByName(accessoryID, room: roomName, in: home) else {
                    throw ControlError.accessoryNotFound(accessoryID + (action["room"].map { " in \($0)" } ?? ""))
                }
                accessory = found
            }

            guard let characteristic = findCharacteristicByDescription(on: accessory, property: property) else {
                throw ControlError.writeFailed("Characteristic '\(property)' not found on \(accessory.name)")
            }

            guard let parsedValue = parseActionValue(valueStr, property: property) else {
                throw ControlError.writeFailed("Cannot parse value '\(valueStr)' for \(property) on \(accessory.name)")
            }

            resolved.append((accessory, characteristic, parsedValue))
        }

        return resolved
    }

    func deleteAutomation(
        id: String,
        homeID: String? = nil,
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()
        let home = try resolveHome(homeID: homeID)
        // Use findAnyTrigger so HMTimerTrigger (Apple Home native time automations)
        // can also be deleted, not just HMEventTrigger.
        guard let trigger = findAnyTrigger(id: id, in: home) else {
            throw ControlError.triggerNotFound(id)
        }

        let triggerName = trigger.name
        let sceneCount = trigger.actionSets.count
        if dryRun {
            return [
                "dry_run": true,
                "name": triggerName,
                "home": home.name,
                "scene_count": sceneCount,
            ] as [String: Any]
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.removeTrigger(trigger) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }

        AppLogger.homekit.info("[\(home.name)] Deleted automation '\(triggerName)'")
        return ["name": triggerName, "home": home.name, "dry_run": false] as [String: Any]
    }

    /// Mutates the action sets attached to an existing automation trigger.
    /// Resolves scene names/UUIDs to HMActionSet, then adds/removes them.
    /// Preserves the trigger's UUID — physical buttons / motion sensors keep firing it.
    func updateAutomationActionSets(
        id: String,
        addSceneIDs: [String],
        removeSceneIDs: [String],
        homeID: String? = nil,
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()
        let home = try resolveHome(homeID: homeID)
        guard let trigger = findTrigger(id: id, in: home) else {
            throw ControlError.triggerNotFound(id)
        }

        var resolvedAdd: [HMActionSet] = []
        var resolvedRemove: [HMActionSet] = []
        var warnings: [String] = []

        for nameOrID in addSceneIDs {
            if let actionSet = home.actionSets.first(where: {
                $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(nameOrID) == .orderedSame
                    || $0.name.localizedCaseInsensitiveCompare(nameOrID) == .orderedSame
            }) {
                if trigger.actionSets.contains(actionSet) {
                    warnings.append("Already attached, skipping add: \(actionSet.name)")
                } else {
                    resolvedAdd.append(actionSet)
                }
            } else {
                warnings.append("Scene not found (add): \(nameOrID)")
            }
        }

        for nameOrID in removeSceneIDs {
            if let actionSet = trigger.actionSets.first(where: {
                $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(nameOrID) == .orderedSame
                    || $0.name.localizedCaseInsensitiveCompare(nameOrID) == .orderedSame
            }) {
                resolvedRemove.append(actionSet)
            } else {
                warnings.append("Scene not attached to this automation (remove): \(nameOrID)")
            }
        }

        let summary: [String: Any] = [
            "id": trigger.uniqueIdentifier.uuidString,
            "name": trigger.name,
            "home": home.name,
            "before": trigger.actionSets.map { $0.name },
            "to_add": resolvedAdd.map { $0.name },
            "to_remove": resolvedRemove.map { $0.name },
            "warnings": warnings,
        ]

        // Refuse operations that would leave the trigger with zero scenes attached.
        // HomeKit doesn't define behavior for an empty actionSets collection — the
        // trigger fires but does nothing, and may become hard to manage in the Home
        // app. Callers wanting to retire a trigger should delete it instead.
        let resultingCount = trigger.actionSets.count + resolvedAdd.count - resolvedRemove.count
        guard resultingCount > 0 else {
            throw ControlError.invalidArgument(
                "Operation would leave trigger '\(trigger.name)' with no attached scenes. Delete the automation instead, or attach a replacement scene.")
        }

        if dryRun {
            var dry = summary
            dry["dry_run"] = true
            return dry
        }

        // Add first so we never leave the trigger with zero action sets midway.
        for actionSet in resolvedAdd {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                trigger.addActionSet(actionSet) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
        for actionSet in resolvedRemove {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                trigger.removeActionSet(actionSet) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }

        AppLogger.homekit.info(
            "[\(home.name)] Rewired automation '\(trigger.name)': +\(resolvedAdd.count) -\(resolvedRemove.count)")

        var result = summary
        result["dry_run"] = false
        result["after"] = trigger.actionSets.map { $0.name }
        return result
    }

    func enableAutomation(
        id: String,
        enabled: Bool,
        homeID: String? = nil
    ) async throws -> [String: Any] {
        await waitForReady()
        let home = try resolveHome(homeID: homeID)
        // Use findAnyTrigger so HMTimerTrigger automations can also be enabled/disabled.
        guard let trigger = findAnyTrigger(id: id, in: home) else {
            throw ControlError.triggerNotFound(id)
        }

        try await homeKitAsync { trigger.enable(enabled, completionHandler: $0) }

        AppLogger.homekit.info("[\(home.name)] \(enabled ? "Enabled" : "Disabled") automation '\(trigger.name)'")
        return [
            "id": trigger.uniqueIdentifier.uuidString,
            "name": trigger.name,
            "enabled": enabled,
            "home": home.name,
        ] as [String: Any]
    }

    // MARK: - Private Helpers

    private func findTrigger(id: String, in home: HMHome) -> HMEventTrigger? {
        findEventTrigger(id: id, in: home)
    }

    /// Lookup an HMEventTrigger by UUID or name (case-insensitive).
    private func findEventTrigger(id: String, in home: HMHome) -> HMEventTrigger? {
        let eventTriggers = home.triggers.compactMap { $0 as? HMEventTrigger }
        if let trigger = eventTriggers.first(where: { $0.uniqueIdentifier.uuidString == id }) {
            return trigger
        }
        return eventTriggers.first(where: { $0.name.localizedCaseInsensitiveCompare(id) == .orderedSame })
    }

    /// Lookup an HMTimerTrigger (Apple Home native time automation) by UUID or name.
    private func findTimerTrigger(id: String, in home: HMHome) -> HMTimerTrigger? {
        let timerTriggers = home.triggers.compactMap { $0 as? HMTimerTrigger }
        if let trigger = timerTriggers.first(where: { $0.uniqueIdentifier.uuidString == id }) {
            return trigger
        }
        return timerTriggers.first(where: { $0.name.localizedCaseInsensitiveCompare(id) == .orderedSame })
    }

    /// Lookup any HMTrigger subclass by UUID or name. Used for delete/enable/disable
    /// where the operation works on the abstract HMTrigger API regardless of subtype.
    private func findAnyTrigger(id: String, in home: HMHome) -> HMTrigger? {
        if let trigger = home.triggers.first(where: { $0.uniqueIdentifier.uuidString == id }) {
            return trigger
        }
        return home.triggers.first(where: { $0.name.localizedCaseInsensitiveCompare(id) == .orderedSame })
    }

    private func findInputEventCharacteristic(
        on accessory: HMAccessory,
        serviceIndex: Int?
    ) throws -> HMCharacteristic {
        // Find all StatelessProgrammableSwitch services
        let switchServices = accessory.services.filter {
            $0.serviceType == HMServiceTypeStatelessProgrammableSwitch
        }

        guard !switchServices.isEmpty else {
            throw ControlError.serviceNotFound(
                "'\(accessory.name)' has no programmable switch services"
            )
        }

        let targetService: HMService
        if let serviceIndex {
            // Match by ServiceLabelIndex characteristic value
            let labelIndexType = CharacteristicMapper.serviceLabelIndexType
            guard let matched = switchServices.first(where: { service in
                guard let indexChar = service.characteristics.first(where: { $0.characteristicType == labelIndexType }),
                      let value = indexChar.value as? NSNumber
                else { return false }
                return value.intValue == serviceIndex
            }) else {
                let available = switchServices.compactMap { service -> String? in
                    guard let indexChar = service.characteristics.first(where: { $0.characteristicType == labelIndexType }),
                          let value = indexChar.value as? NSNumber
                    else { return nil }
                    return "\(value.intValue)"
                }
                throw ControlError.serviceNotFound(
                    "No button with service_index \(serviceIndex) on '\(accessory.name)'. Available: \(available.joined(separator: ", "))"
                )
            }
            targetService = matched
        } else if switchServices.count == 1 {
            targetService = switchServices[0]
        } else {
            // Multiple switch services, index required
            let labelIndexType = CharacteristicMapper.serviceLabelIndexType
            let indices = switchServices.compactMap { service -> String? in
                guard let indexChar = service.characteristics.first(where: { $0.characteristicType == labelIndexType }),
                      let value = indexChar.value as? NSNumber
                else { return nil }
                return "\(value.intValue)"
            }
            throw ControlError.serviceNotFound(
                "'\(accessory.name)' has \(switchServices.count) buttons. Specify --service-index (\(indices.joined(separator: ", ")))"
            )
        }

        // Find the input_event characteristic on the selected service
        guard let inputEvent = targetService.characteristics.first(where: {
            $0.characteristicType == HMCharacteristicTypeInputEvent
        }) else {
            throw ControlError.characteristicNotFound(
                "input_event not found on '\(accessory.name)' button service"
            )
        }

        return inputEvent
    }

    /// Finds a characteristic by its human-readable name on any service of the accessory.
    private func findTriggerCharacteristic(
        on accessory: HMAccessory,
        characteristicName: String
    ) throws -> HMCharacteristic {
        guard let charType = CharacteristicMapper.characteristicType(forName: characteristicName) else {
            throw ControlError.characteristicNotFound("Unknown characteristic: '\(characteristicName)'")
        }
        for service in accessory.services {
            if let char = service.characteristics.first(where: { $0.characteristicType == charType }) {
                return char
            }
        }
        throw ControlError.characteristicNotFound(
            "'\(accessory.name)' has no '\(characteristicName)' characteristic"
        )
    }

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
            guard let accessoryID = action["accessory"],
                  let property = action["property"],
                  let valueStr = action["value"]
            else {
                warnings.append("Skipping action with missing fields: \(action)")
                continue
            }

            // Try UUID first, then name with optional room disambiguator
            let accessory: HMAccessory
            if let found = home.accessories.first(where: { $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(accessoryID) == .orderedSame }) {
                accessory = found
            } else {
                let roomName = action["room"]
                guard let found = findAccessoryByName(accessoryID, room: roomName, in: home) else {
                    warnings.append("Accessory not found: \(accessoryID)" + (roomName.map { " in \($0)" } ?? ""))
                    continue
                }
                accessory = found
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

    /// Replaces the actions on an existing scene in-place, preserving its UUID
    /// so any automations that reference the scene continue to work.
    /// Lookup by UUID first, then by case-insensitive name.
    func updateScene(
        nameOrID: String,
        homeName: String? = nil,
        actions: [[String: String]],
        dryRun: Bool = false
    ) async throws -> [String: Any] {
        await waitForReady()
        let targetHomes = filteredHomes(homeID: homeName)

        var foundActionSet: HMActionSet?
        var foundHome: HMHome?
        for home in targetHomes {
            if let actionSet = home.actionSets.first(where: {
                $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(nameOrID) == .orderedSame
                    || $0.name.localizedCaseInsensitiveCompare(nameOrID) == .orderedSame
            }) {
                foundActionSet = actionSet
                foundHome = home
                break
            }
        }
        guard let actionSet = foundActionSet, let home = foundHome else {
            throw ControlError.accessoryNotFound("Scene not found: \(nameOrID)")
        }

        var resolvedActions: [(accessory: HMAccessory, characteristic: HMCharacteristic, value: Any)] = []
        var warnings: [String] = []

        for action in actions {
            guard let accessoryID = action["accessory"],
                  let property = action["property"],
                  let valueStr = action["value"]
            else {
                warnings.append("Skipping action with missing fields: \(action)")
                continue
            }

            let accessory: HMAccessory
            if let found = home.accessories.first(where: {
                $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(accessoryID) == .orderedSame
            }) {
                accessory = found
            } else {
                let roomName = action["room"]
                guard let found = findAccessoryByName(accessoryID, room: roomName, in: home) else {
                    warnings.append("Accessory not found: \(accessoryID)" + (roomName.map { " in \($0)" } ?? ""))
                    continue
                }
                accessory = found
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
                "name": actionSet.name,
                "id": actionSet.uniqueIdentifier.uuidString,
                "home": home.name,
                "existing_action_count": actionSet.actions.count,
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

        // Refuse to wipe a scene when caller asked for actions but every one
        // failed to resolve. (Empty input is a legitimate clear-all request.)
        if !actions.isEmpty && resolvedActions.isEmpty {
            throw ControlError.invalidArgument(
                "All \(actions.count) action(s) failed to resolve; scene '\(actionSet.name)' not modified.")
        }

        // Snapshot the pre-existing actions BEFORE any mutation. Used to drive
        // the remove loop below. We can't rely on `actionSet.actions.subtracting(addedActions)`
        // post-add because HomeKit may wrap/replace the HMAction we provide
        // before storing it; the reference we hold in `addedActions` may not
        // match the one in `actionSet.actions` by identity, and HMAction is
        // hashed/equated as NSObject (reference equality).
        let oldActions = Array(actionSet.actions)

        // Add new actions BEFORE removing the old ones. If `addAction` throws
        // partway through, the original actions are still attached, so the
        // scene retains its prior behavior (and the partial adds will trigger
        // alongside the originals — redundant but not destructive). We then
        // best-effort clean up any partial adds before propagating the error.
        var addedActions: [HMAction] = []
        do {
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
                addedActions.append(writeAction)
            }
        } catch {
            // Roll back the partial adds so the scene returns to its prior state.
            for action in addedActions {
                try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    actionSet.removeAction(action) { _ in continuation.resume() }
                }
            }
            throw error
        }
        let addedCount = addedActions.count

        // Remove only the pre-snapshotted originals.
        for action in oldActions {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                actionSet.removeAction(action) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
        let removedCount = oldActions.count

        AppLogger.homekit.info(
            "[\(home.name)] Updated scene '\(actionSet.name)': added \(addedCount), removed \(removedCount)")

        return [
            "updated": true,
            "name": actionSet.name,
            "id": actionSet.uniqueIdentifier.uuidString,
            "home": home.name,
            "removed_action_count": removedCount,
            "added_action_count": addedCount,
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

        // Properties that are always numeric — never interpret "0"/"1" as boolean
        let numericProperties: Set<String> = [
            "target_position", "current_position", "brightness", "hue", "saturation",
            "color_temperature", "target_temperature", "rotation_speed", "battery_level",
            "volume", "volume_control_type", "rotation_direction", "position_state",
            "current_tilt_angle", "target_tilt_angle", "swing_mode",
            "target_fan_state", "current_fan_state",
            "current_heating_cooling", "target_heating_cooling",
            "current_humidity", "target_humidity", "current_light_level",
            "charging_state", "lock_current_state", "lock_target_state",
            "current_door_state", "target_door_state", "contact_state",
        ]
        let isNumericProperty = numericProperties.contains(property.lowercased())

        // Boolean ON/OFF — but only for non-numeric properties
        if !isNumericProperty {
            switch trimmed.uppercased() {
            case "ON", "TRUE": return NSNumber(value: true)
            case "OFF", "FALSE": return NSNumber(value: false)
            case "1": return NSNumber(value: true)
            case "0": return NSNumber(value: false)
            default: break
            }
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
        if Self.isDemoMode { return DemoFixtures.allAccessoriesWithHome() }
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
        if Self.isDemoMode { return DemoFixtures.menuData() }

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
