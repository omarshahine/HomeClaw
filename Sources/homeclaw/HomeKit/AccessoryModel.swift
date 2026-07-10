import HomeKit

private extension NSExpression {
    /// `NSExpression.constantValue` is only defined on the constant-expression
    /// subclass and throws ObjC NSInvalidArgumentException on any other type
    /// (notably NSFunctionExpression). HomeKit returns function expressions in
    /// some automation predicates, which crashes the whole process. Guard with
    /// expressionType.
    var safeConstantValue: Any? {
        expressionType == .constantValue ? constantValue : nil
    }
}

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
    /// Includes the distinct rooms touched by the scene's actions, so callers
    /// can decide whether the scene is room-scoped or home-scoped.
    static func sceneSummary(_ actionSet: HMActionSet) -> [String: Any] {
        var rooms = Set<String>()
        for action in actionSet.actions {
            guard let write = action as? HMCharacteristicWriteAction<NSCopying> else { continue }
            if let room = write.characteristic.service?.accessory?.room?.name {
                rooms.insert(room)
            }
        }
        return [
            "id": actionSet.uniqueIdentifier.uuidString,
            "name": actionSet.name,
            "action_count": actionSet.actions.count,
            "type": actionSetType(actionSet),
            "rooms": Array(rooms).sorted(),
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
                "accessory_id": accessory?.uniqueIdentifier.uuidString ?? "",
                "room": accessory?.room?.name ?? "Default Room",
                "characteristic": CharacteristicMapper.name(for: characteristic.characteristicType),
                "value": "\(writeAction.targetValue)",
            ]
        }
        detail["actions"] = actions
        detail["action_count"] = actions.count
        return detail
    }

    // MARK: - Automations (Triggers)

    /// Uniform scene (action set) references for a trigger, shared by list and get
    /// so both surfaces emit the same representation (issue #76): `id` + `name` +
    /// `action_count`, plus `hidden: true` for trigger-owned action sets that the
    /// Home app excludes from `home.actionSets` (their names are opaque UUID
    /// strings, which is why a "name" can look like a UUID).
    static func triggerActionSetSummaries(_ trigger: HMTrigger, home: HMHome?) -> [[String: Any]] {
        let visibleIDs = home.map { Set($0.actionSets.map(\.uniqueIdentifier)) }
        return trigger.actionSets.map { actionSet in
            var dict: [String: Any] = [
                "id": actionSet.uniqueIdentifier.uuidString,
                "name": actionSet.name,
                "action_count": actionSet.actions.count,
            ]
            if let visibleIDs, !visibleIDs.contains(actionSet.uniqueIdentifier) {
                dict["hidden"] = true
            }
            return dict
        }
    }

    /// Dispatch summary by trigger subclass. Routes HMEventTrigger to `automationSummary`,
    /// HMTimerTrigger to `timerTriggerSummary`, and returns a minimal placeholder for any
    /// other HMTrigger subclass so unknown triggers are still visible to callers.
    /// Pass `home` to flag trigger-owned hidden action sets in the scene references.
    static func triggerSummary(_ trigger: HMTrigger, homeName: String, home: HMHome? = nil) -> [String: Any] {
        if let event = trigger as? HMEventTrigger {
            return automationSummary(event, homeName: homeName, home: home)
        }
        if let timer = trigger as? HMTimerTrigger {
            return timerTriggerSummary(timer, homeName: homeName, home: home)
        }
        return [
            "id": trigger.uniqueIdentifier.uuidString,
            "name": trigger.name,
            "enabled": trigger.isEnabled,
            "home": homeName,
            "trigger_type": "unknown",
        ]
    }

    /// Summary of a time-based timer trigger (Apple Home native time automation,
    /// created via the iOS Home app).
    static func timerTriggerSummary(_ trigger: HMTimerTrigger, homeName: String, home: HMHome? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            "id": trigger.uniqueIdentifier.uuidString,
            "name": trigger.name,
            "enabled": trigger.isEnabled,
            "home": homeName,
            "trigger_type": "timer",
            "scene_count": trigger.actionSets.count,
            "scenes": trigger.actionSets.map { $0.name },
            "action_sets": triggerActionSetSummaries(trigger, home: home),
        ]
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeOfDay = formatter.string(from: trigger.fireDate)
        var summary = "at \(timeOfDay)"
        if let recurrence = trigger.recurrence {
            if let day = recurrence.day, day == 1 { summary += " daily" }
            else if let weekday = recurrence.weekday {
                let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                if (1...7).contains(weekday) { summary += " on \(names[weekday])s" }
            }
        }
        dict["event_summary"] = summary
        dict["fire_time"] = timeOfDay
        dict["fire_date"] = ISO8601DateFormatter().string(from: trigger.fireDate)
        return dict
    }

    /// Detailed view of a timer trigger including full scene/action breakdown,
    /// matching the richness of `automationDetail` for HMEventTriggers.
    static func timerTriggerDetail(_ trigger: HMTimerTrigger, homeName: String, home: HMHome? = nil) -> [String: Any] {
        var detail = timerTriggerSummary(trigger, homeName: homeName, home: home)

        // Enrich the shared summary shape with each scene's resolved actions.
        let actionSets: [[String: Any]] = zip(trigger.actionSets, triggerActionSetSummaries(trigger, home: home)).map { actionSet, summary in
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
            var dict = summary
            dict["actions"] = actions
            return dict
        }
        detail["action_sets"] = actionSets

        // Surface unparsed recurrence DateComponents for callers that want raw access.
        // (Partial decoding lives in `timerTriggerSummary`'s event_summary.)
        if let recurrence = trigger.recurrence {
            var raw: [String: Int] = [:]
            if let v = recurrence.day { raw["day"] = v }
            if let v = recurrence.weekday { raw["weekday"] = v }
            if let v = recurrence.weekOfMonth { raw["weekOfMonth"] = v }
            if let v = recurrence.weekOfYear { raw["weekOfYear"] = v }
            if let v = recurrence.month { raw["month"] = v }
            if let v = recurrence.year { raw["year"] = v }
            if let v = recurrence.hour { raw["hour"] = v }
            if let v = recurrence.minute { raw["minute"] = v }
            if let v = recurrence.second { raw["second"] = v }
            if !raw.isEmpty {
                detail["recurrence_raw"] = raw
            }
        }

        return detail
    }

    /// Summary of an automation (event trigger) for list views.
    /// Pass `home` to flag trigger-owned hidden action sets in `action_sets`.
    static func automationSummary(_ trigger: HMEventTrigger, homeName: String, home: HMHome? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            "id": trigger.uniqueIdentifier.uuidString,
            "name": trigger.name,
            "enabled": trigger.isEnabled,
            "home": homeName,
            "scene_count": trigger.actionSets.count,
            "scenes": trigger.actionSets.map { $0.name },
            "action_sets": triggerActionSetSummaries(trigger, home: home),
        ]

        // Build a human-readable event summary from the first event.
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
        // Characteristic threshold-range event ("light level ≤ 15 lux"). This is a
        // distinct HMEvent subclass — NOT an HMCharacteristicEvent — so the cast above
        // fails for it and it must be handled separately (see #65).
        else if let thresholdEvent = trigger.events.first as? HMCharacteristicThresholdRangeEvent,
                let accessory = thresholdEvent.characteristic.service?.accessory
        {
            let charType = thresholdEvent.characteristic.characteristicType
            let charName = CharacteristicMapper.name(for: charType)
            let range = thresholdEvent.thresholdRange
            dict["event_summary"] = "\(accessory.name) \(charName) \(thresholdRangeSummary(range, charType: charType))"
            dict["trigger_type"] = "threshold"

            var thresholdInfo: [String: Any] = [
                "accessory_id": accessory.uniqueIdentifier.uuidString,
                "accessory_name": accessory.name,
                "characteristic": charName,
            ]
            if let minValue = range.minValue {
                thresholdInfo["min"] = CharacteristicMapper.formatValue(minValue, for: charType)
            }
            if let maxValue = range.maxValue {
                thresholdInfo["max"] = CharacteristicMapper.formatValue(maxValue, for: charType)
            }
            if let idx = serviceIndexForCharacteristic(thresholdEvent.characteristic) {
                thresholdInfo["service_index"] = idx
            }
            dict["trigger_info"] = thresholdInfo
        }
        // Calendar event (HH:MM time-of-day on an HMEventTrigger).
        else if let calEvent = trigger.events.first as? HMCalendarEvent {
            let dc = calEvent.fireDateComponents
            if let hour = dc.hour, let minute = dc.minute {
                dict["event_summary"] = String(format: "at %02d:%02d", hour, minute)
                dict["fire_time"] = String(format: "%02d:%02d", hour, minute)
            }
            dict["trigger_type"] = "calendar"
        }
        // Significant-time event (sunrise/sunset).
        else if let sigEvent = trigger.events.first as? HMSignificantTimeEvent {
            let label = sigEvent.significantEvent == .sunrise ? "sunrise" : "sunset"
            var summary = "at \(label)"
            if let off = sigEvent.offset {
                let totalMinutes = (off.hour ?? 0) * 60 + (off.minute ?? 0)
                if totalMinutes != 0 {
                    summary += totalMinutes > 0 ? "+\(totalMinutes)m" : "\(totalMinutes)m"
                }
            }
            dict["event_summary"] = summary
            dict["trigger_type"] = "significant_time"
        }
        // Unrecognized HMEvent subclass — keep schema's "unknown" contract
        // consistent with `triggerSummary`'s fallback for non-HMEventTrigger triggers.
        else {
            dict["trigger_type"] = "unknown"
        }

        // Surface auto-off duration (HMDurationEvent in endEvents).
        if let durationEvent = trigger.endEvents.compactMap({ $0 as? HMDurationEvent }).first {
            let seconds = Int(durationEvent.duration.rounded())
            dict["duration_seconds"] = seconds
            if let existing = dict["event_summary"] as? String {
                dict["event_summary"] = existing + " (off after \(formatDuration(seconds)))"
            }
        }

        // Brief condition count in the event summary so list views show the predicate is non-trivial.
        // Full structured conditions are surfaced by `automationDetail` and `extractConditions`.
        // We pass `home: nil` here because this summary path doesn't have access to it; weekdays
        // and time predicates are still counted, characteristic accessory names just won't resolve.
        // (`automationDetail` uses the home-scoped variant for richer output.)
        let conditionCount = countConditions(trigger.predicate)
        if conditionCount > 0, let existing = dict["event_summary"] as? String {
            dict["event_summary"] = existing + " (+\(conditionCount) condition\(conditionCount == 1 ? "" : "s"))"
        }

        return dict
    }

    /// Format a duration in seconds as a compact string (e.g. "5m", "2h", "30s").
    private static func formatDuration(_ seconds: Int) -> String {
        if seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    /// Human-readable summary of a threshold range (HMCharacteristicThresholdRangeEvent).
    /// HomeKit encodes one-sided thresholds ("≤ 15 lux") with a single bound and bounded
    /// ranges with both. Values are formatted through CharacteristicMapper for the type.
    private static func thresholdRangeSummary(_ range: HMNumberRange, charType: String) -> String {
        let minStr = range.minValue.map { CharacteristicMapper.formatValue($0, for: charType) }
        let maxStr = range.maxValue.map { CharacteristicMapper.formatValue($0, for: charType) }
        switch (minStr, maxStr) {
        case let (min?, max?): return "between \(min) and \(max)"
        case let (min?, nil): return "≥ \(min)"
        case let (nil, max?): return "≤ \(max)"
        default: return "in range"
        }
    }

    /// Detailed view of an automation including all events and linked scenes.
    /// Pass `home` to resolve characteristic-condition predicates to accessory names.
    static func automationDetail(_ trigger: HMEventTrigger, homeName: String, home: HMHome? = nil) -> [String: Any] {
        var detail = automationSummary(trigger, homeName: homeName, home: home)

        let events: [[String: Any]] = trigger.events.compactMap { event in
            // Characteristic equality / button event.
            if let charEvent = event as? HMCharacteristicEvent<NSCopying> {
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

            // Characteristic threshold-range event ("light level ≤ 15 lux"). Distinct
            // HMEvent subclass from HMCharacteristicEvent — handled explicitly (see #65).
            if let thresholdEvent = event as? HMCharacteristicThresholdRangeEvent {
                let characteristic = thresholdEvent.characteristic
                let charType = characteristic.characteristicType
                let accessory = characteristic.service?.accessory
                let range = thresholdEvent.thresholdRange

                var eventDict: [String: Any] = [
                    "type": "threshold",
                    "characteristic": CharacteristicMapper.name(for: charType),
                    "trigger_type": "threshold",
                    "summary": thresholdRangeSummary(range, charType: charType),
                ]
                if let accessory {
                    eventDict["accessory"] = accessory.name
                    eventDict["accessory_id"] = accessory.uniqueIdentifier.uuidString
                }
                if let service = characteristic.service {
                    eventDict["service_type"] = CharacteristicMapper.serviceCategory(for: service.serviceType) ?? service.serviceType
                }
                if let minValue = range.minValue {
                    eventDict["min"] = CharacteristicMapper.formatValue(minValue, for: charType)
                }
                if let maxValue = range.maxValue {
                    eventDict["max"] = CharacteristicMapper.formatValue(maxValue, for: charType)
                }
                if let idx = serviceIndexForCharacteristic(characteristic) {
                    eventDict["service_index"] = idx
                }
                return eventDict
            }

            return nil
        }
        detail["events"] = events

        // `action_sets` is already populated by `automationSummary` via
        // `triggerActionSetSummaries`, keeping list and get identical (issue #76).

        // Decode the trigger predicate into structured conditions. Skipped when there's no
        // predicate at all, or when nothing decodes (rather than emitting an empty array
        // — keeps existing JSON consumers from seeing a new-but-always-empty key).
        let conditions = extractConditions(trigger.predicate, in: home)
        if !conditions.isEmpty {
            detail["conditions"] = conditions
        }

        return detail
    }

    // MARK: - Predicate decoding

    /// Decode an automation trigger's NSPredicate into a structured array of conditions.
    /// Returns dicts with a `type` discriminator: `characteristic`, `weekdays`, `time`
    /// (sun-relative or clock time-of-day), or `unknown` (a real conjunct we couldn't decode,
    /// surfaced as a placeholder rather than dropped). Each kind has its own field shape (see
    /// inline comments). Pass `home` to resolve characteristic UUIDs to accessory names;
    /// without it characteristic conditions fall back to a `characteristic_id` lookup hint.
    static func extractConditions(_ predicate: NSPredicate?, in home: HMHome?) -> [[String: Any]] {
        guard let predicate else { return [] }

        // UUID → (accessory, characteristic) lookup so we can name characteristic conditions.
        var charMap: [String: (accessory: HMAccessory, characteristic: HMCharacteristic)] = [:]
        if let home {
            for accessory in home.accessories {
                for service in accessory.services {
                    for char in service.characteristics {
                        charMap[char.uniqueIdentifier.uuidString.uppercased()] = (accessory, char)
                    }
                }
            }
        }

        var subpredicates: [NSPredicate] = []
        flattenTopAnd(predicate, into: &subpredicates)

        return subpredicates.compactMap { sub -> [String: Any]? in
            // Weekday OR-compound (--days output): OR of comparisons against DateComponents.weekday.
            if let orCompound = sub as? NSCompoundPredicate, orCompound.compoundPredicateType == .or {
                var weekdays: [Int] = []
                for inner in (orCompound.subpredicates as? [NSPredicate] ?? []) {
                    if let cmp = inner as? NSComparisonPredicate,
                       let dc = (cmp.rightExpression.safeConstantValue ?? cmp.leftExpression.safeConstantValue) as? DateComponents,
                       let wd = dc.weekday
                    {
                        weekdays.append(wd)
                    }
                }
                if !weekdays.isEmpty {
                    let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
                    let sorted = weekdays.sorted()
                    return [
                        "type": "weekdays",
                        "weekdays": sorted,
                        "summary": sorted.map { names[$0 - 1] }.joined(separator: ","),
                    ]
                }
            }

            // Single-weekday predicate (rare — produced when --days has exactly one entry).
            if let cmp = sub as? NSComparisonPredicate,
               let dc = (cmp.rightExpression.safeConstantValue ?? cmp.leftExpression.safeConstantValue) as? DateComponents,
               let wd = dc.weekday
            {
                let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
                return ["type": "weekdays", "weekdays": [wd], "summary": names[wd - 1]]
            }

            // Sun-relative time predicate (--time-after / --time-before): NSComparisonPredicate
            // referencing the `sunrise`/`sunset` HMSignificantEvent string. We can't reliably
            // recover the offset from the public predicate API, so offset_minutes is omitted
            // when not 0/representable; the field is always present for shape stability.
            if let cmp = sub as? NSComparisonPredicate {
                for expr in [cmp.leftExpression, cmp.rightExpression] {
                    if let eventStr = expr.safeConstantValue as? String,
                       (eventStr == HMSignificantEvent.sunrise.rawValue || eventStr == HMSignificantEvent.sunset.rawValue)
                    {
                        let eventName = eventStr == HMSignificantEvent.sunrise.rawValue ? "sunrise" : "sunset"
                        let isBefore = cmp.predicateOperatorType == .lessThan || cmp.predicateOperatorType == .lessThanOrEqualTo
                        let relation = isBefore ? "before" : "after"
                        return [
                            "type": "time",
                            "relation": relation,
                            "event": eventName,
                            "summary": "\(relation) \(eventName)",
                        ]
                    }
                }
            }

            // Time-of-day predicate ("Time is between 16:00 and 00:00", or before/after a
            // clock time). Home-app conditions compare the current time against a
            // DateComponents holding hour/minute; the opposite side is an NSFunctionExpression
            // (the "now" extraction) — the node that crashed unguarded `constantValue`
            // traversal before #62's `safeConstantValue` guard. A "between" range is stored as
            // an AND of an after-bound and a before-bound, which `flattenTopAnd` splits into two
            // conjuncts that each decode here as a separate `time` condition. We read whichever
            // side is the DateComponents constant and infer the relation from the operator,
            // accounting for which side holds the constant.
            if let cmp = sub as? NSComparisonPredicate {
                let constOnRight = cmp.rightExpression.safeConstantValue is DateComponents
                if let dc = (cmp.rightExpression.safeConstantValue ?? cmp.leftExpression.safeConstantValue) as? DateComponents,
                   dc.weekday == nil, let hour = dc.hour
                {
                    let clock = String(format: "%02d:%02d", hour, dc.minute ?? 0)
                    // `now <op> dc` (constant on the right) vs `dc <op> now` (constant on the
                    // left) invert the meaning of an ordered comparison. Operators outside the
                    // known set fall through to `unknownCondition` rather than guessing.
                    let relation: String
                    switch cmp.predicateOperatorType {
                    case .equalTo:
                        relation = "at"
                    case .lessThan, .lessThanOrEqualTo:
                        relation = constOnRight ? "before" : "after"
                    case .greaterThan, .greaterThanOrEqualTo:
                        relation = constOnRight ? "after" : "before"
                    default:
                        return unknownCondition(sub)
                    }
                    return [
                        "type": "time",
                        "relation": relation,
                        "time": clock,
                        "summary": relation == "at" ? "at \(clock)" : "\(relation) \(clock)",
                    ]
                }
            }

            // Characteristic predicate: HomeKit wraps each as a 2-sub AND
            // (characteristic == <HMCharacteristic> AND characteristicValue == X).
            guard let compound = sub as? NSCompoundPredicate, compound.compoundPredicateType == .and else { return unknownCondition(sub) }
            let inner = compound.subpredicates as? [NSPredicate] ?? []
            var foundChar: HMCharacteristic?
            var foundValue: String?
            for innerSub in inner {
                guard let cmp = innerSub as? NSComparisonPredicate else { continue }
                if let hmChar = cmp.rightExpression.safeConstantValue as? HMCharacteristic {
                    foundChar = hmChar
                } else if let val = cmp.rightExpression.safeConstantValue {
                    foundValue = "\(val)"
                }
            }
            guard let char = foundChar, let value = foundValue else { return unknownCondition(sub) }
            let uuid = char.uniqueIdentifier.uuidString.uppercased()
            if let entry = charMap[uuid] {
                return [
                    "type": "characteristic",
                    "accessory": entry.accessory.name,
                    "accessory_id": entry.accessory.uniqueIdentifier.uuidString,
                    "property": CharacteristicMapper.name(for: entry.characteristic.characteristicType),
                    "operator": "==",
                    "value": value,
                ]
            }
            // Fallback when home lookup is unavailable — surface the raw UUID so callers can resolve.
            return [
                "type": "characteristic",
                "characteristic_id": uuid,
                "operator": "==",
                "value": value,
            ]
        }
    }

    /// Lightweight count of decoded conditions, used by `automationSummary` to annotate
    /// `event_summary` without paying the home-scoped lookup cost.
    private static func countConditions(_ predicate: NSPredicate?) -> Int {
        extractConditions(predicate, in: nil).count
    }

    /// Placeholder for a top-level predicate conjunct we recognize as a real condition node
    /// but can't decode into a typed shape. Surfacing it (instead of silently dropping it via
    /// `nil`) keeps `automations get` honest about unsupported conditions (#65). Uses
    /// `predicateFormat` for a debugging hint — safe on `NSFunctionExpression`, unlike
    /// `constantValue`, since the format string is built from each expression's `description`.
    private static func unknownCondition(_ predicate: NSPredicate) -> [String: Any] {
        var dict: [String: Any] = ["type": "unknown", "summary": "unsupported condition"]
        let format = predicate.predicateFormat
        if !format.isEmpty {
            dict["predicate_format"] = format.count > 200 ? String(format.prefix(200)) + "…" : format
        }
        return dict
    }

    /// Flatten nested top-level AND compounds into a flat subpredicate list.
    /// Successive `updatePredicate` mutations from `add-condition` (which appends
    /// new condition leaves to a trigger's existing predicate) can produce AND-of-
    /// ANDs whose top-level is flat but whose children are themselves the standard
    /// HMEventTrigger characteristic-leaf compounds. This function flattens
    /// unconditionally with `isCharacteristicLeaf` as the leaf signal, so callers
    /// see a flat conjunct list regardless of write-time nesting.
    ///
    /// The characteristic predicate `(characteristic == X AND value == Y)` is a leaf — both
    /// subs are NSComparisonPredicate referencing an HMCharacteristic — so we keep it intact
    /// for the decoder below. Any other AND (mixed comparisons + compounds, e.g. a single
    /// weekday plus a characteristic conjunct, or auto-filled weekdays plus a sun-relative
    /// time predicate) must be flattened so each conjunct can be decoded individually.
    private static func flattenTopAnd(_ p: NSPredicate, into out: inout [NSPredicate]) {
        guard let cmp = p as? NSCompoundPredicate, cmp.compoundPredicateType == .and else {
            out.append(p)
            return
        }
        let subs = cmp.subpredicates as? [NSPredicate] ?? []
        if isCharacteristicLeaf(subs) {
            out.append(p)
            return
        }
        for sub in subs { flattenTopAnd(sub, into: &out) }
    }

    /// Determines whether an NSPredicate is the "characteristic leaf" shape HomeKit
    /// uses to represent a single condition: a 2-element AND of comparisons, with an
    /// HMCharacteristic constant on either side of one comparison. Used by
    /// `extractConditions` via `flattenTopAnd` on the read side, and by
    /// `HomeKitManager.addAutomationCondition` on the write side to decide whether
    /// to wrap or flatten an existing predicate. Introduced for the decoder fix in
    /// 34fd00f; reused for the writer in this PR to keep the leaf-recognition
    /// vocabulary in lockstep.
    static func isCharacteristicLeaf(_ subs: [NSPredicate]) -> Bool {
        guard subs.count == 2 else { return false }
        let comparisons = subs.compactMap { $0 as? NSComparisonPredicate }
        guard comparisons.count == 2 else { return false }
        return comparisons.contains { cmp in
            cmp.rightExpression.safeConstantValue is HMCharacteristic
                || cmp.leftExpression.safeConstantValue is HMCharacteristic
        }
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
