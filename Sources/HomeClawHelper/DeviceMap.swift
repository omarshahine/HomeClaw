import HomeKit

/// LLM-optimized device map generation and semantic type inference.
/// Pure-computation enum — all methods called from @MainActor contexts.
enum DeviceMap {
    // MARK: - Semantic Types

    enum SemanticType: String, CaseIterable, Sendable {
        case lighting, climate, security, door_lock, window_covering
        case sensor, power, media, network, other
    }

    // MARK: - Semantic Type Inference

    /// Infers the semantic type for an accessory by examining both its category
    /// AND its services. Unlike `inferredCategoryName` (which only checks services
    /// when category is "other"), this always inspects services to catch cases like
    /// Lutron switches that control lightbulbs.
    static func inferSemanticType(for accessory: HMAccessory) -> SemanticType {
        let category = CharacteristicMapper.inferredCategoryName(for: accessory)

        switch category {
        case "lightbulb":
            return .lighting
        case "switch", "programmable_switch":
            return .power
        case "thermostat", "fan", "air_purifier":
            return .climate
        case "lock":
            return .door_lock
        case "door", "garage_door", "security_system", "camera", "doorbell":
            return .security
        case "sensor":
            return .sensor
        case "outlet":
            return .power
        case "window", "window_covering":
            return .window_covering
        case "speaker", "television":
            return .media
        case "network":
            return .network
        default:
            return .other
        }
    }

    // MARK: - Zone Resolution

    struct ResolvedZone {
        let name: String
        let rooms: [HMRoom]
    }

    /// Resolves zones for a home. Uses existing HomeKit zones when available,
    /// groups unzoned rooms separately, falls back to home name if no zones exist.
    static func resolveZones(for home: HMHome) -> [ResolvedZone] {
        let zones = home.zones
        guard !zones.isEmpty else {
            return [ResolvedZone(name: home.name, rooms: home.rooms)]
        }

        var result: [ResolvedZone] = []
        var zonedRoomIDs = Set<UUID>()

        for zone in zones {
            result.append(ResolvedZone(name: zone.name, rooms: zone.rooms))
            for room in zone.rooms {
                zonedRoomIDs.insert(room.uniqueIdentifier)
            }
        }

        let unzoned = home.rooms.filter { !zonedRoomIDs.contains($0.uniqueIdentifier) }
        if !unzoned.isEmpty {
            result.append(ResolvedZone(name: "(Unzoned)", rooms: unzoned))
        }

        return result
    }

    // MARK: - Display Name Disambiguation

    /// Computes disambiguated display names for accessories with duplicate names.
    /// Names appearing 2+ times get "{Room} {Name}". Unique names stay as-is.
    static func computeDisplayNames(for accessories: [HMAccessory]) -> [UUID: String] {
        var nameGroups: [String: [HMAccessory]] = [:]
        for accessory in accessories {
            nameGroups[accessory.name.lowercased(), default: []].append(accessory)
        }

        var result: [UUID: String] = [:]
        for (_, group) in nameGroups {
            if group.count >= 2 {
                for accessory in group {
                    let room = accessory.room?.name ?? "Unknown"
                    result[accessory.uniqueIdentifier] = "\(room) \(accessory.name)"
                }
            } else if let accessory = group.first {
                result[accessory.uniqueIdentifier] = accessory.name
            }
        }
        return result
    }

    // MARK: - Auto-Alias Generation

    /// Generates LLM-friendly aliases for search matching. All lowercased.
    static func generateAliases(
        accessory: HMAccessory,
        semanticType: SemanticType,
        category: String,
        accessories: [HMAccessory]? = nil
    ) -> [String] {
        let name = accessory.name.lowercased()
        let room = accessory.room?.name.lowercased() ?? ""

        var aliases: [String] = []

        if !room.isEmpty {
            aliases.append("\(room) \(name)")
            aliases.append("\(name) in \(room)")

            // Lighting devices AND plain switches get light/lights aliases.
            // In-wall switches (Lutron Caséta, etc.) are overwhelmingly light
            // switches; this ensures "kitchen light" matches them via alias.
            // Programmable switches, outlets, and other categories are excluded.
            if semanticType == .lighting || category == "switch" {
                aliases.append("\(room) light")
                aliases.append("\(room) lights")
            }
        }

        // Manufacturer alias when single device from that mfr in the room
        if let manufacturer = accessory.manufacturer?.lowercased(),
           !room.isEmpty,
           let allAccessories = accessories
        {
            let sameManufacturerInRoom = allAccessories.filter {
                $0.room?.name.lowercased() == room
                    && $0.manufacturer?.lowercased() == manufacturer
            }
            if sameManufacturerInRoom.count == 1 {
                aliases.append("\(manufacturer) in \(room)")
            }
        }

        return aliases
    }

    // MARK: - State Summary

    /// Generates a one-line state summary from cached state values.
    static func stateSummary(
        from state: [String: String]?,
        category: String,
        reachable: Bool
    ) -> String {
        guard reachable else { return "unreachable" }
        guard let state, !state.isEmpty else { return "unknown" }

        switch category {
        case "lightbulb", "switch":
            let power = state["power"]
            let brightness = state["brightness"]
            if power == "true" || power == "1" {
                if let brightness { return "on \(brightness)%" }
                return "on"
            } else if power == "false" || power == "0" {
                return "off"
            }
            return "unknown"

        case "thermostat":
            var parts: [String] = []
            if let temp = state["current_temperature"] { parts.append(temp) }
            if let mode = state["current_heating_cooling"], mode != "off" { parts.append(mode) }
            return parts.isEmpty ? "unknown" : parts.joined(separator: " ")

        case "lock":
            return state["lock_current_state"] ?? "unknown"

        case "door", "garage_door":
            return state["current_door_state"] ?? "unknown"

        case "window_covering":
            if let position = state["current_position"] { return "\(position)%" }
            return "unknown"

        case "fan":
            if let active = state["active"] {
                if active == "true" || active == "1" {
                    if let speed = state["rotation_speed"] { return "on \(speed)%" }
                    return "on"
                }
                return "off"
            }
            return "unknown"

        case "sensor":
            var parts: [String] = []
            if let temp = state["current_temperature"] { parts.append(temp) }
            if let humidity = state["current_humidity"] { parts.append("\(humidity)% humidity") }
            if let motion = state["motion_detected"], motion == "true" { parts.append("motion") }
            if let contact = state["contact_state"] { parts.append("contact: \(contact)") }
            return parts.isEmpty ? "unknown" : parts.joined(separator: ", ")

        default:
            if let power = state["power"] {
                return power == "true" || power == "1" ? "on" : "off"
            }
            if let active = state["active"] {
                return active == "true" || active == "1" ? "on" : "off"
            }
            return "unknown"
        }
    }

    // MARK: - Controllable Characteristics

    /// Returns human-readable names of writable characteristics on the accessory.
    static func controllableCharacteristics(for accessory: HMAccessory) -> [String] {
        var controllable: [String] = []
        for service in accessory.services {
            for characteristic in service.characteristics {
                if CharacteristicMapper.isWritable(characteristic.characteristicType) {
                    let name = CharacteristicMapper.name(for: characteristic.characteristicType)
                    if !controllable.contains(name) {
                        controllable.append(name)
                    }
                }
            }
        }
        return controllable
    }

    // MARK: - Description Generation

    /// Generates a compact natural-language description for an accessory.
    static func generateDescription(
        accessory: HMAccessory,
        semanticType: SemanticType,
        controllable: [String],
        stateSummary: String?
    ) -> String {
        var parts: [String] = []

        if let manufacturer = accessory.manufacturer {
            parts.append(manufacturer)
        }

        parts.append(semanticType.rawValue)

        if !controllable.isEmpty {
            parts.append("(\(controllable.joined(separator: ", ")))")
        }

        var desc = parts.joined(separator: " ")

        if let summary = stateSummary, summary != "unknown" {
            desc += ", \(summary)"
        }

        return desc
    }

    // MARK: - Map Builder

    /// Builds the complete LLM-optimized device map from live HomeKit data.
    static func buildMap(
        homes: [HMHome],
        filter: ([HMAccessory]) -> [HMAccessory],
        cache: CharacteristicCache
    ) -> [String: Any] {
        let timestamp = ISO8601DateFormatter().string(from: Date())

        // Global computations across all filtered accessories
        let allFiltered = homes.flatMap { filter($0.accessories) }
        let displayNames = computeDisplayNames(for: allFiltered)

        // Stats
        var semanticTypeCounts: [String: Int] = [:]
        var reachableCount = 0

        // Check for name collisions
        let nameGroups = Dictionary(grouping: allFiltered) { $0.name.lowercased() }
        let hasCollisions = nameGroups.values.contains { $0.count >= 2 }

        // Build home → zone → room → device tree
        var homesList: [[String: Any]] = []

        for home in homes {
            let zones = resolveZones(for: home)
            var zonesList: [[String: Any]] = []

            for zone in zones {
                var roomsList: [[String: Any]] = []

                for room in zone.rooms {
                    let roomAccessories = filter(room.accessories)
                    guard !roomAccessories.isEmpty else { continue }

                    var devicesList: [[String: Any]] = []

                    for accessory in roomAccessories {
                        let id = accessory.uniqueIdentifier
                        let category = CharacteristicMapper.inferredCategoryName(for: accessory)
                        let semanticType = inferSemanticType(for: accessory)
                        let controllable = controllableCharacteristics(for: accessory)
                        let cachedState = cache.cachedState(for: id.uuidString)
                        let summary = stateSummary(
                            from: cachedState, category: category, reachable: accessory.isReachable
                        )
                        let aliases = generateAliases(
                            accessory: accessory, semanticType: semanticType,
                            category: category, accessories: allFiltered
                        )
                        let description = generateDescription(
                            accessory: accessory, semanticType: semanticType,
                            controllable: controllable, stateSummary: summary
                        )
                        let displayName = displayNames[id] ?? accessory.name

                        // Stats
                        semanticTypeCounts[semanticType.rawValue, default: 0] += 1
                        if accessory.isReachable { reachableCount += 1 }

                        var device: [String: Any] = [
                            "id": id.uuidString,
                            "name": accessory.name,
                            "category": category,
                            "semantic_type": semanticType.rawValue,
                            "description": description,
                            "aliases": aliases,
                            "controllable": controllable,
                            "state_summary": summary,
                            "reachable": accessory.isReachable,
                        ]

                        if displayName != accessory.name {
                            device["display_name"] = displayName
                        }
                        if let manufacturer = accessory.manufacturer {
                            device["manufacturer"] = manufacturer
                        }

                        devicesList.append(device)
                    }

                    if !devicesList.isEmpty {
                        roomsList.append([
                            "name": room.name,
                            "devices": devicesList,
                        ])
                    }
                }

                if !roomsList.isEmpty {
                    zonesList.append([
                        "name": zone.name,
                        "rooms": roomsList,
                    ])
                }
            }

            homesList.append([
                "name": home.name,
                "id": home.uniqueIdentifier.uuidString,
                "zones": zonesList,
            ])
        }

        var result: [String: Any] = [
            "generated_at": timestamp,
            "stats": [
                "total": allFiltered.count,
                "reachable": reachableCount,
                "by_semantic_type": semanticTypeCounts,
            ] as [String: Any],
            "homes": homesList,
        ]

        if hasCollisions {
            result["disambiguation_note"] =
                "Multiple devices share the same name. Use display_name (which includes room prefix) or aliases for unambiguous identification."
        }

        return result
    }
}
