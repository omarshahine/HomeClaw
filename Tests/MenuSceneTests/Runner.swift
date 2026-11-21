import AppKit
import Foundation

@MainActor final class TrapBridge: NSObject, Mac2iOS {
    var calls: [String] = []
    var isLaunchAtLoginEnabled: Bool { false }
    func setLaunchAtLogin(_ enabled: Bool) { calls.append("setLaunchAtLogin") }
    func refreshData() { calls.append("refreshData") }
    func currentMenuData() -> [String: Any] { calls.append("currentMenuData"); return [:] }
    func openSettings() { calls.append("openSettings") }
    func quitApp() { calls.append("quitApp") }
    func controlAccessory(id: String, characteristic: String, value: String) { calls.append("controlAccessory") }
    func triggerScene(id: String) { calls.append("triggerScene") }
    func selectHome(id: String) { calls.append("selectHome") }
}

@main struct Runner {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    @MainActor static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
    }
    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let target = HMRoom("Target Room"), other = HMRoom("Other Room")
        let targetLamp = HMAccessory(11, "Target Lamp", room: target)
        let otherLamp = HMAccessory(12, "Other Lamp", room: other)
        let unscoped = HMAccessory(13, "Unscoped Lamp", room: nil)
        target.accessories = [targetLamp]; other.accessories = [otherLamp]
        let wanted = [
            HMActionSet(101, "Home A", accessories: [unscoped]),
            HMActionSet(102, "Home B", accessories: [unscoped]),
            HMActionSet(103, "Multi A", accessories: [targetLamp, otherLamp]),
            HMActionSet(104, "Multi B", accessories: [targetLamp, otherLamp]),
            HMActionSet(105, "Other A", accessories: [otherLamp]),
            HMActionSet(106, "Other B", accessories: [otherLamp]),
            HMActionSet(107, "Target A", accessories: [targetLamp]),
            HMActionSet(108, "Target B", accessories: [targetLamp]),
        ]
        let zeroBuiltin = HMActionSet(201, "Good Morning", type: HMActionSetTypeWakeUp, accessories: [])
        let builtinControl = HMActionSet(202, "Good Night", type: HMActionSetTypeSleep, accessories: [targetLamp])
        let home = HMHome(rooms: [target, other], scenes: wanted + [zeroBuiltin, builtinControl])
        home.accessories = [targetLamp, otherLamp, unscoped]
        let manager = FixtureManager(home: home)
        let controller = MacOSController(), bridge = TrapBridge()
        controller.iOSBridge = bridge
        let wantedIDs = Set(wanted.map { $0.uniqueIdentifier.uuidString })
        let selectedAll = Set(home.accessories.map { $0.uniqueIdentifier.uuidString })
        let base = manager.buildMenuData()
        let originalScenes = try JSONSerialization.data(withJSONObject: base["scenes"]!, options: [.sortedKeys])
        var cases: [[String: Any]] = []

        func inspect(_ name: String, _ snapshot: [String: Any], disabled: Set<UUID> = [], identicalScenes: Bool = false) throws {
            let scenes = snapshot["scenes"] as! [[String: Any]]
            if identicalScenes {
                try require(try JSONSerialization.data(withJSONObject: scenes, options: [.sortedKeys]) == originalScenes,
                            "\(name): scene array changed")
            }
            let menu = controller.fixtureMenu(snapshot)
            let sceneIDs = Set(scenes.compactMap { $0["id"] as? String })
            let items = menu.items.filter { ($0.representedObject as? String).map(sceneIDs.contains) == true }
            try require(items.count == scenes.count, "\(name): a scene vanished or was duplicated")
            try require(wantedIDs.isSubset(of: Set(items.compactMap { $0.representedObject as? String })), "\(name): fewer than eight wanted scenes")
            var labels: [[String: Any]] = []
            for item in items {
                let id = item.representedObject as! String
                let input = scenes.first { $0["id"] as? String == id }!
                let rawName = input["name"] as? String ?? "?"
                let expectedName = rawName.isEmpty ? "Unnamed Scene" : rawName
                let enabled = !disabled.contains(UUID(uuidString: id)!)
                try require(item.title == expectedName, "\(name): wrong scene label")
                try require(item.isEnabled == enabled, "\(name): wrong enabled state for \(item.title)")
                try require(item.action.map(NSStringFromSelector) == (enabled ? "triggerScene:" : nil), "\(name): disabled scene has an action")
                try require(enabled || !(item.toolTip ?? "").isEmpty, "\(name): missing disabled explanation")
                labels.append(["id": id, "title": item.title, "enabled": item.isEnabled, "tooltip": item.toolTip ?? ""])
            }
            cases.append(["case": name, "input_scenes": scenes, "scene_items": labels, "wanted_visible": wantedIDs.count])
            print("PASS \(name): 8/8 wanted, \(disabled.count) disabled with explanations")
        }

        try inspect("retained-room", base, identicalScenes: true)
        var empty = base
        empty["rooms"] = (base["rooms"] as! [[String: Any]]).map { room in
            var room = room
            if room["name"] as? String == target.name { room["accessories"] = [] as [[String: Any]] }
            return room
        }
        try inspect("empty-but-present-room", empty, identicalScenes: true)
        var missing = base
        missing["rooms"] = (base["rooms"] as! [[String: Any]]).filter { $0["name"] as? String != target.name }
        try inspect("released-six-of-eight-missing-room", missing, identicalScenes: true)
        target.accessories = []
        try inspect("actual-builder-empty-room", manager.buildMenuData(), identicalScenes: true)
        target.accessories = [targetLamp]

        HomeClawConfig.shared.filterMode = "allowlist"
        HomeClawConfig.shared.allowedIDs = selectedAll
        try inspect("selected-only-all-allowed", manager.buildMenuData())
        HomeClawConfig.shared.allowedIDs = [otherLamp.uniqueIdentifier.uuidString, unscoped.uniqueIdentifier.uuidString]
        let targetExcluded = Set([wanted[2], wanted[3], wanted[6], wanted[7], builtinControl].map(\.uniqueIdentifier))
        try inspect("selected-only-excluded-room-and-mixed-actions", manager.buildMenuData(), disabled: targetExcluded)
        // Previously enabled menu items must not bypass a later selection change.
        for scene in [wanted[2], wanted[6]] {
            do {
                _ = try await manager.triggerScene(id: scene.uniqueIdentifier.uuidString, fromMenu: true)
                throw Failure(message: "Stale menu executed excluded or mixed actions")
            } catch FixtureManager.ControlError.sceneUnavailableFromMenu { }
        }
        try require(home.executions.isEmpty, "A blocked scene reached the fake executor")
        _ = try await manager.triggerScene(id: wanted[4].uniqueIdentifier.uuidString, fromMenu: true)
        try require(home.executions == [wanted[4].uniqueIdentifier], "Allowed menu scene was blocked")
        home.executions = []

        HomeClawConfig.shared.allowedIDs = [targetLamp.uniqueIdentifier.uuidString, unscoped.uniqueIdentifier.uuidString]
        try inspect("selected-only-other-room-excluded", manager.buildMenuData(), disabled: Set(wanted[2...5].map(\.uniqueIdentifier)))
        HomeClawConfig.shared.allowedIDs = nil
        try inspect("selected-only-selection-unavailable", manager.buildMenuData(), disabled: Set((wanted + [builtinControl]).map(\.uniqueIdentifier)))

        let unsupported = HMActionSet(301, "Unknown Action", accessories: [])
        unsupported.actions = [NSObject()]
        let mixedUnknown = HMActionSet(302, "Mixed Unknown", accessories: [unscoped])
        mixedUnknown.actions.append(NSObject())
        let noService = HMActionSet(303, "Missing Service", accessories: [targetLamp])
        (noService.actions[0] as! HMCharacteristicWriteAction<NSCopying>).characteristic.service = nil
        let noAccessory = HMActionSet(304, "Missing Accessory", accessories: [targetLamp])
        (noAccessory.actions[0] as! HMCharacteristicWriteAction<NSCopying>).characteristic.service?.accessory = nil
        let dangling = HMAccessory(14, "Stale Accessory", room: target)
        let stale = HMActionSet(305, "Stale Accessory Scene", accessories: [dangling])
        let unresolved = [unsupported, mixedUnknown, noService, noAccessory, stale]
        home.actionSets += unresolved
        HomeClawConfig.shared.allowedIDs = selectedAll.union([dangling.uniqueIdentifier.uuidString])
        try inspect("selected-only-unresolved-and-mixed-unresolved", manager.buildMenuData(), disabled: Set(unresolved.map(\.uniqueIdentifier)))
        for scene in unresolved {
            do {
                _ = try await manager.triggerScene(id: scene.uniqueIdentifier.uuidString, fromMenu: true)
                throw Failure(message: "Menu executed unresolved actions")
            } catch FixtureManager.ControlError.sceneUnavailableFromMenu { }
        }
        try require(home.executions.isEmpty, "Unresolved menu scene reached fake executor")
        // Default route is the existing CLI/MCP path; it still executes the full set.
        HomeClawConfig.shared.allowedIDs = [otherLamp.uniqueIdentifier.uuidString]
        for scene in [wanted[6], wanted[2], mixedUnknown] {
            _ = try await manager.triggerScene(id: scene.uniqueIdentifier.uuidString)
        }
        try require(home.executions == [wanted[6], wanted[2], mixedUnknown].map(\.uniqueIdentifier), "CLI/MCP execution policy changed")
        HomeClawConfig.shared.filterMode = "all"
        try inspect("unrestricted-unresolved-keeps-existing-behavior", manager.buildMenuData())
        home.executions = []
        _ = try await manager.triggerScene(id: mixedUnknown.uniqueIdentifier.uuidString, fromMenu: true)
        try require(home.executions == [mixedUnknown.uniqueIdentifier], "Unrestricted menu execution changed")
        home.actionSets = wanted + [zeroBuiltin, builtinControl]
        zeroBuiltin.name = ""
        try inspect("literal-empty-name-fallback", manager.buildMenuData())
        zeroBuiltin.name = "Good Morning"
        try inspect("named-zero-action-built-in-unchanged", manager.buildMenuData())
        var missingName = base
        missingName["scenes"] = (base["scenes"] as! [[String: Any]]).map { scene in
            var scene = scene
            if scene["id"] as? String == zeroBuiltin.uniqueIdentifier.uuidString { scene.removeValue(forKey: "name") }
            return scene
        }
        try inspect("missing-name-key-keeps-question-mark", missingName)

        try require(bridge.calls.isEmpty && !NSApplication.shared.isActive, "Fixture invoked UI/bridge actions")
        let result: [String: Any] = ["cases": cases, "bridge_calls": bridge.calls,
                                   "menu_execution_checks": 9, "unchanged_cli_execution_checks": 3]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
        print("PASS \(cases.count) actual NSMenu cases, 9 menu execution checks and 3 unchanged CLI/MCP checks; only in-memory fake execution")
    }
}
