import HomeKit

/// Converts HomeKit objects into serializable dictionaries for MCP tool responses and CLI output.
enum AccessoryModel {
    /// Summary of a home.
    static func homeSummary(_ home: HMHome) -> [String: Any] {
        [
            "id": home.uniqueIdentifier.uuidString,
            "name": home.name,
            "is_primary": home.isPrimary,
            "room_count": home.rooms.count,
            "accessory_count": home.accessories.count,
            "scene_count": home.actionSets.count,
        ]
    }

    /// Summary of a room (accessories populated separately by caller with cache-aware logic).
    static func roomSummary(_ room: HMRoom) -> [String: Any] {
        [
            "id": room.uniqueIdentifier.uuidString,
            "name": room.name,
            "accessory_count": room.accessories.count,
        ]
    }

    /// Brief summary of an accessory (for list views).
    /// - Parameters:
    ///   - cachedState: Pre-computed state from cache. If nil, reads from characteristic.value.
    ///   - zone: Zone name from DeviceMap zone resolution.
    ///   - displayName: Disambiguated display name (only included when different from name).
    ///   - semanticType: Semantic type string from DeviceMap inference.
    static func accessorySummary(
        _ accessory: HMAccessory,
        cachedState: [String: String]? = nil,
        zone: String? = nil,
        displayName: String? = nil,
        semanticType: String? = nil
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "id": accessory.uniqueIdentifier.uuidString,
            "name": accessory.name,
            "category": CharacteristicMapper.inferredCategoryName(for: accessory),
            "reachable": accessory.isReachable,
        ]
        if let room = accessory.room {
            dict["room"] = room.name
        }

        // Enrichment fields
        if let zone { dict["zone"] = zone }
        if let displayName, displayName != accessory.name { dict["display_name"] = displayName }
        if let semanticType { dict["semantic_type"] = semanticType }
        if let manufacturer = accessory.manufacturer { dict["manufacturer"] = manufacturer }

        // Use cached state if provided, otherwise read from characteristic objects
        let state: [String: String]
        if let cachedState, !cachedState.isEmpty {
            state = cachedState
        } else {
            var built: [String: String] = [:]
            for service in accessory.services {
                for characteristic in service.characteristics {
                    let name = CharacteristicMapper.name(for: characteristic.characteristicType)
                    if isInterestingState(name) {
                        built[name] = CharacteristicMapper.formatValue(
                            characteristic.value, for: characteristic.characteristicType
                        )
                    }
                }
            }
            state = built
        }
        if !state.isEmpty {
            dict["state"] = state
        }

        return dict
    }

    /// Full detail of an accessory (for get views).
    static func accessoryDetail(_ accessory: HMAccessory) -> [String: Any] {
        var dict: [String: Any] = [
            "id": accessory.uniqueIdentifier.uuidString,
            "name": accessory.name,
            "category": CharacteristicMapper.inferredCategoryName(for: accessory),
            "reachable": accessory.isReachable,
            "bridged": accessory.isBridged,
        ]
        if let room = accessory.room {
            dict["room"] = room.name
            dict["room_id"] = room.uniqueIdentifier.uuidString
        }
        if let manufacturer = accessory.manufacturer { dict["manufacturer"] = manufacturer }
        if let model = accessory.model { dict["model"] = model }
        if let firmware = accessory.firmwareVersion { dict["firmware"] = firmware }

        // Services and their characteristics
        var services: [[String: Any]] = []
        for service in accessory.services {
            var chars: [[String: Any]] = []
            for characteristic in service.characteristics {
                let charName = CharacteristicMapper.name(for: characteristic.characteristicType)
                var charDict: [String: Any] = [
                    "name": charName,
                    "type": characteristic.characteristicType,
                    "value": CharacteristicMapper.formatValue(
                        characteristic.value, for: characteristic.characteristicType
                    ),
                    "writable": CharacteristicMapper.isWritable(characteristic.characteristicType),
                ]

                if let metadata = characteristic.metadata {
                    var meta: [String: Any] = [:]
                    if let format = metadata.format { meta["format"] = format }
                    if let minValue = metadata.minimumValue { meta["min"] = minValue }
                    if let maxValue = metadata.maximumValue { meta["max"] = maxValue }
                    if let stepValue = metadata.stepValue { meta["step"] = stepValue }
                    if let units = metadata.units { meta["units"] = units }
                    if !meta.isEmpty { charDict["metadata"] = meta }
                }

                chars.append(charDict)
            }

            services.append([
                "name": service.name,
                "type": service.serviceType,
                "characteristics": chars,
            ])
        }
        dict["services"] = services

        return dict
    }

    /// Summary of a scene (action set).
    static func sceneSummary(_ actionSet: HMActionSet) -> [String: Any] {
        [
            "id": actionSet.uniqueIdentifier.uuidString,
            "name": actionSet.name,
            "action_count": actionSet.actions.count,
            "type": actionSetType(actionSet),
        ]
    }

    // MARK: - Helpers

    static func isInterestingState(_ name: String) -> Bool {
        let interesting: Set<String> = [
            "power", "brightness", "current_temperature", "target_temperature",
            "current_heating_cooling", "target_heating_cooling",
            "lock_current_state", "lock_target_state",
            "current_door_state", "target_door_state",
            "motion_detected", "contact_state", "battery_level",
            "active", "current_humidity", "color_temperature",
            "current_position", "target_position",
        ]
        return interesting.contains(name)
    }

    private static func actionSetType(_ actionSet: HMActionSet) -> String {
        switch actionSet.actionSetType {
        case HMActionSetTypeWakeUp: return "wake_up"
        case HMActionSetTypeSleep: return "sleep"
        case HMActionSetTypeHomeDeparture: return "leave"
        case HMActionSetTypeHomeArrival: return "arrive"
        default: return "user_defined"
        }
    }
}
