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

        // Home app display name (only when different from raw name)
        let homeDisplayName = computeHomeAppDisplayName(for: accessory, roomName: accessory.room?.name)
        if homeDisplayName != accessory.name {
            dict["home_display_name"] = homeDisplayName
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

    /// Detailed view of a scene including all actions.
    static func sceneDetail(_ actionSet: HMActionSet) -> [String: Any] {
        var detail = sceneSummary(actionSet)
        let actions: [[String: String]] = actionSet.actions.compactMap { action in
            guard let writeAction = action as? HMCharacteristicWriteAction<NSCopying> else { return nil }
            let characteristic = writeAction.characteristic
            let accessory = characteristic.service?.accessory
            return [
                "accessory": accessory?.name ?? "Unknown",
                "room": accessory?.room?.name ?? "Default Room",
                "characteristic": CharacteristicMapper.name(for: characteristic.characteristicType),
                "value": "\(writeAction.targetValue)",
            ]
        }
        detail["actions"] = actions
        detail["action_count"] = actions.count
        return detail
    }

    // MARK: - Automations (Event Triggers)

    /// Summary of an automation (event trigger) for list views.
    static func automationSummary(_ trigger: HMEventTrigger, homeName: String) -> [String: Any] {
        var dict: [String: Any] = [
            "id": trigger.uniqueIdentifier.uuidString,
            "name": trigger.name,
            "enabled": trigger.isEnabled,
            "home": homeName,
            "scene_count": trigger.actionSets.count,
            "scenes": trigger.actionSets.map { $0.name },
        ]

        // Build a human-readable event summary from the first characteristic event
        if let event = trigger.events.first as? HMCharacteristicEvent<NSCopying>,
           let accessory = event.characteristic.service?.accessory
        {
            let charType = event.characteristic.characteristicType
            let isButton = charType == HMCharacteristicTypeInputEvent

            if isButton {
                let pressValue = (event.triggerValue as? NSNumber)?.intValue
                let pressName = pressValue.map { pressTypeName($0) } ?? "any_press"
                dict["event_summary"] = "\(accessory.name) \(pressName)"
                dict["trigger_type"] = "button"

                var buttonInfo: [String: Any] = [
                    "accessory_id": accessory.uniqueIdentifier.uuidString,
                    "accessory_name": accessory.name,
                    "press_type": pressName,
                ]
                if let idx = serviceIndexForCharacteristic(event.characteristic) {
                    buttonInfo["service_index"] = idx
                }
                dict["button_info"] = buttonInfo
            } else {
                let charName = CharacteristicMapper.name(for: charType)
                let formattedValue = CharacteristicMapper.formatValue(event.triggerValue, for: charType)
                dict["event_summary"] = "\(accessory.name) \(charName) = \(formattedValue)"
                dict["trigger_type"] = "characteristic"

                dict["trigger_info"] = [
                    "accessory_id": accessory.uniqueIdentifier.uuidString,
                    "accessory_name": accessory.name,
                    "characteristic": charName,
                    "trigger_value": formattedValue,
                ] as [String: Any]
            }
        }

        return dict
    }

    /// Detailed view of an automation including all events and linked scenes.
    static func automationDetail(_ trigger: HMEventTrigger, homeName: String) -> [String: Any] {
        var detail = automationSummary(trigger, homeName: homeName)

        let events: [[String: Any]] = trigger.events.compactMap { event in
            guard let charEvent = event as? HMCharacteristicEvent<NSCopying> else { return nil }
            let characteristic = charEvent.characteristic
            let charType = characteristic.characteristicType
            let accessory = characteristic.service?.accessory
            let isButton = charType == HMCharacteristicTypeInputEvent

            var eventDict: [String: Any] = [
                "type": "characteristic",
                "characteristic": CharacteristicMapper.name(for: charType),
                "trigger_type": isButton ? "button" : "characteristic",
            ]
            if let accessory {
                eventDict["accessory"] = accessory.name
                eventDict["accessory_id"] = accessory.uniqueIdentifier.uuidString
            }
            if let service = characteristic.service {
                eventDict["service_type"] = CharacteristicMapper.serviceCategory(for: service.serviceType) ?? service.serviceType
            }
            if isButton {
                let pressValue = (charEvent.triggerValue as? NSNumber)?.intValue
                if let pressValue {
                    eventDict["trigger_value"] = pressValue
                    eventDict["press_type"] = pressTypeName(pressValue)
                }
            } else {
                let formattedValue = CharacteristicMapper.formatValue(charEvent.triggerValue, for: charType)
                eventDict["trigger_value"] = formattedValue
            }
            if let idx = serviceIndexForCharacteristic(characteristic) {
                eventDict["service_index"] = idx
            }
            return eventDict
        }
        detail["events"] = events

        let actionSets: [[String: Any]] = trigger.actionSets.map { actionSet in
            [
                "id": actionSet.uniqueIdentifier.uuidString,
                "name": actionSet.name,
                "action_count": actionSet.actions.count,
            ]
        }
        detail["action_sets"] = actionSets

        return detail
    }

    /// Maps press type integer to human-readable name.
    static func pressTypeName(_ value: Int) -> String {
        switch value {
        case 0: "single_press"
        case 1: "double_press"
        case 2: "long_press"
        default: "press_\(value)"
        }
    }

    /// Reads the ServiceLabelIndex value from the same service as the given characteristic.
    private static func serviceIndexForCharacteristic(_ characteristic: HMCharacteristic) -> Int? {
        guard let service = characteristic.service else { return nil }
        guard let indexChar = service.characteristics.first(where: { $0.characteristicType == CharacteristicMapper.serviceLabelIndexType }),
              let value = indexChar.value as? NSNumber
        else { return nil }
        return value.intValue
    }

    // MARK: - Home App Display Name

    /// Service types where the Home app prefers the service name over the accessory name.
    private static let serviceNamePreferredTypes: Set<String> = [
        HMServiceTypeGarageDoorOpener,
        HMServiceTypeDoor,
        HMServiceTypeWindowCovering,
        HMServiceTypeWindow,
    ]

    /// Computes the display name that Apple's Home app would show for an accessory.
    /// Applies two transformations:
    /// 1. Prefers the service name for garage doors, window coverings, etc.
    /// 2. Strips the room name prefix (e.g. "Garage Aqara Hub" in "Garage" → "Aqara Hub")
    static func computeHomeAppDisplayName(for accessory: HMAccessory, roomName: String?) -> String {
        var name = accessory.name

        // Prefer service name for garage doors, window coverings, etc.
        for service in accessory.services {
            if serviceNamePreferredTypes.contains(service.serviceType) && !service.name.isEmpty {
                name = service.name
                break
            }
        }

        // Strip room prefix ("Garage Aqara Hub" in "Garage" room → "Aqara Hub")
        if let roomName, !roomName.isEmpty {
            let prefix = roomName + " "
            if name.hasPrefix(prefix) && name.count > prefix.count {
                name = String(name.dropFirst(prefix.count))
            }
        }

        return name
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
            "input_event", "occupancy_detected",
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
