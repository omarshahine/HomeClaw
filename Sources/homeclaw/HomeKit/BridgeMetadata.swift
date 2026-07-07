import HomeKit

/// Bridge ownership metadata derived from HomeKit bridge accessories.
///
/// HomeKit exposes bridge relationships from the bridge side: a bridge accessory
/// lists the accessories it vends. This type builds the inverse lookup so child
/// accessories can report the bridge that owns them.
///
/// Respects an optional visibility predicate so a caller-side allowlist (see
/// `HomeClawConfig.filterMode == "allowlist"`) is not silently bypassed. When
/// `isAccessoryVisible` returns false for a bridge, that bridge's summary is
/// never attached to any child. When it returns false for a child, that
/// child's UUID is dropped from the bridge's `bridged_accessory_ids` list and
/// the child never receives the bridge summary.
struct BridgeMetadata {
    private let bridgeByAccessoryID: [UUID: [String: Any]]
    private let bridgedAccessoryIDsByBridgeID: [UUID: [String]]

    init(homes: [HMHome], isAccessoryVisible: (HMAccessory) -> Bool = { _ in true }) {
        var bridgeByAccessoryID: [UUID: [String: Any]] = [:]
        var bridgedAccessoryIDsByBridgeID: [UUID: [String]] = [:]

        for home in homes {
            // Index this home's accessories once so we can look up visibility
            // of each bridged child without an O(n) walk per child.
            var accessoryByID: [UUID: HMAccessory] = [:]
            for accessory in home.accessories {
                accessoryByID[accessory.uniqueIdentifier] = accessory
            }

            for bridge in home.accessories {
                guard isAccessoryVisible(bridge) else { continue }

                let allChildIDs = Self.bridgedAccessoryIdentifiers(for: bridge)
                guard !allChildIDs.isEmpty else { continue }

                // Only surface children that are themselves visible. An unknown
                // child (present in the identifier list but missing from
                // home.accessories) is dropped defensively — we can't confirm
                // it passes the allowlist.
                let visibleChildIDs = allChildIDs.filter { childID in
                    guard let child = accessoryByID[childID] else { return false }
                    return isAccessoryVisible(child)
                }
                guard !visibleChildIDs.isEmpty else { continue }

                bridgedAccessoryIDsByBridgeID[bridge.uniqueIdentifier] = visibleChildIDs.map(\.uuidString)
                let summary = Self.bridgeSummary(for: bridge)
                for childID in visibleChildIDs {
                    bridgeByAccessoryID[childID] = summary
                }
            }
        }

        self.bridgeByAccessoryID = bridgeByAccessoryID
        self.bridgedAccessoryIDsByBridgeID = bridgedAccessoryIDsByBridgeID
    }

    func bridgeSummary(for accessory: HMAccessory) -> [String: Any]? {
        bridgeByAccessoryID[accessory.uniqueIdentifier]
    }

    func bridgedAccessoryIDs(for bridge: HMAccessory) -> [String] {
        bridgedAccessoryIDsByBridgeID[bridge.uniqueIdentifier] ?? []
    }

    private static func bridgedAccessoryIdentifiers(for bridge: HMAccessory) -> [UUID] {
        var ids = Set<UUID>()

        for accessory in bridge.bridgedAccessories {
            ids.insert(accessory.uniqueIdentifier)
        }

        for id in bridge.uniqueIdentifiersForBridgedAccessories ?? [] {
            ids.insert(id)
        }

        return ids.sorted { lhs, rhs in
            lhs.uuidString.localizedStandardCompare(rhs.uuidString) == .orderedAscending
        }
    }

    private static func bridgeSummary(for bridge: HMAccessory) -> [String: Any] {
        var dict: [String: Any] = [
            "id": bridge.uniqueIdentifier.uuidString,
            "name": bridge.name,
            "category": CharacteristicMapper.inferredCategoryName(for: bridge),
            "reachable": bridge.isReachable,
        ]

        if let room = bridge.room {
            dict["room"] = room.name
            dict["room_id"] = room.uniqueIdentifier.uuidString
        }
        if let manufacturer = bridge.manufacturer { dict["manufacturer"] = manufacturer }
        if let model = bridge.model { dict["model"] = model }
        if let firmware = bridge.firmwareVersion { dict["firmware"] = firmware }

        return dict
    }
}
