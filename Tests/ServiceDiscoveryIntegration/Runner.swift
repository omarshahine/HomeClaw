import Foundation

@main struct Runner {
    struct Failure: Error { let message: String }
    @MainActor static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
    }
    @MainActor static func run() async throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var checks: [String] = []
        func check(_ name: String, _ condition: Bool) throws {
            guard condition else { throw Failure(message: name) }
            checks.append(name); print("PASS \(name)")
        }
        func gang(_ n: Int, _ name: String, _ power: Bool, _ index: Int) -> HMService {
            HMService(n, name, type: HMServiceTypeSwitch, associated: HMServiceTypeLightbulb,
                      chars: [HMCharacteristic(HMCharacteristicTypePowerState, power),
                              HMCharacteristic(CharacteristicMapper.serviceLabelIndexType, NSNumber(value: index))])
        }
        let dining = gang(11, "餐厅灯", true, 1), kitchen = gang(12, "厨房灯", false, 2)
        let ota = HMService(13, "Private OTA", type: "private-ota", chars: [HMCharacteristic("private-firmware", true)])
        let a = HMAccessory(1, "WS04-S2 - 7", services: [dining, ota, kitchen])
        let hidden = HMAccessory(2, "WS04-S2 hidden", services: [gang(21, "餐厅灯", false, 1), gang(22, "厨房灯", true, 2)])
        let single = HMAccessory(3, "Single switch", services: [gang(31, "Single channel", true, 1)])
        let readOnly = HMAccessory(4, "Read-only services", services: (1...2).map {
            HMService(40 + $0, "Read-only \($0)", type: HMServiceTypeSwitch, associated: HMServiceTypeLightbulb,
                      chars: [HMCharacteristic(HMCharacteristicTypePowerState, true, writable: false)])
        })
        let identifyOnly = HMAccessory(5, "Identify-only services", services: (1...2).map {
            HMService(50 + $0, "Identify-only \($0)", type: HMServiceTypeSwitch, associated: HMServiceTypeLightbulb,
                      chars: [HMCharacteristic(HMCharacteristicTypeIdentify, true)])
        })
        let manager = FixtureManager([HMHome([HMRoom([a, hidden, single, readOnly, identifyOnly])])])
        func row(_ rows: [[String: Any]], _ accessory: HMAccessory) -> [String: Any] {
            rows.first { $0["id"] as? String == accessory.uniqueIdentifier.uuidString } ?? [:]
        }
        func channelsCorrect(_ device: [String: Any]) -> Bool {
            guard let channels = device["services"] as? [[String: Any]] else { return false }
            return channels.compactMap { $0["id"] as? String } == [dining, kitchen].map { $0.uniqueIdentifier.uuidString }
                && channels.compactMap { $0["name"] as? String } == ["餐厅灯", "厨房灯"]
                && channels.compactMap { ($0["state"] as? [String: String])?["power"] } == ["true", "false"]
                && channels.compactMap { $0["index"] as? Int } == [1, 2]
                && channels.allSatisfy { $0["display_as"] as? String == "light" && $0["state_source"] as? String == "last_known" }
        }
        func devices(_ map: [String: Any]) -> [[String: Any]] {
            (map["homes"] as? [[String: Any]] ?? []).flatMap { $0["zones"] as? [[String: Any]] ?? [] }
                .flatMap { $0["rooms"] as? [[String: Any]] ?? [] }
                .flatMap { $0["devices"] as? [[String: Any]] ?? [] }
        }
        let list = await manager.listAccessories()
        try check("list exposes distinct Chinese channels and per-service state, skipping OTA", channelsCorrect(row(list, a)))
        try check("collapsed accessory cache is not copied into both gangs", (row(list, a)["state"] as? [String: String])?["power"] == "true" && channelsCorrect(row(list, a)))
        try check("single, read-only and identify-only services keep compact summary", [single, readOnly, identifyOnly].allSatisfy { row(list, $0)["services"] == nil })
        let rooms = await manager.listRooms()
        try check("rooms reuse channel summaries", channelsCorrect(row(rooms.first?["accessories"] as? [[String: Any]] ?? [], a)))
        let search = await manager.searchAccessories(query: "厨房灯", category: "LIGHTBULB")
        try check("search matches service name outside assigned room and Display As category", search.count == 2 && channelsCorrect(row(search, a)))
        try check("search preserves accessory category", row(search, a)["category"] as? String == "switch")
        let legacySearch = await manager.searchAccessories(query: "WS04", category: "switch")
        try check("legacy accessory-name/category search preserved", legacySearch.count == 2)
        let fanSearch = await manager.searchAccessories(query: "WS04", category: "fan")
        try check("unrelated Display As category excluded", fanSearch.isEmpty)
        let map = await manager.deviceMap()
        try check("device map exposes the same distinct services", channelsCorrect(row(devices(map), a)))
        try check("device map aliases include both service names", Set(row(devices(map), a)["aliases"] as? [String] ?? []).isSuperset(of: ["餐厅灯", "厨房灯"]))
        HomeClawConfig.shared.filterMode = "allowlist"
        HomeClawConfig.shared.allowedIDs = [a.uniqueIdentifier.uuidString]
        let selected = await manager.searchAccessories(query: "厨房灯", category: "lightbulb")
        try check("Selected Only search excludes identically named hidden channels", selected.count == 1 && channelsCorrect(selected[0]))
        HomeClawConfig.shared.allowedIDs = [single.uniqueIdentifier.uuidString]
        let selectedList = await manager.listAccessories(), selectedRooms = await manager.listRooms()
        let selectedMap = await manager.deviceMap(), selectedSearch = await manager.searchAccessories(query: "厨房灯")
        let output: [String: Any] = ["list": selectedList, "rooms": selectedRooms, "map": selectedMap, "search": selectedSearch]
        let serialized = String(data: try JSONSerialization.data(withJSONObject: output), encoding: .utf8)!
        try check("Selected Only list/rooms/search/map leak no excluded channel names", !serialized.contains("厨房灯") && !serialized.contains("餐厅灯") && selectedSearch.isEmpty && selectedList.count == 1 && devices(selectedMap).count == 1)
        try JSONSerialization.data(withJSONObject: ["checks": checks, "list": list, "search": search, "map": map], options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("results.json"))
        print("PASS \(checks.count) production discovery checks; only in-memory doubles, no HomeKit framework or I/O")
    }
}
