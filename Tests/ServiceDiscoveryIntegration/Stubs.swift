import Foundation

func fixtureID(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
struct HMCategory { let categoryType: String }
final class HMCharacteristic {
    let characteristicType: String
    let value: Any?
    let properties: [String]
    init(_ type: String, _ value: Any?, writable: Bool = true) {
        characteristicType = type; self.value = value
        properties = writable ? [HMCharacteristicPropertyWritable] : []
    }
}
final class HMService {
    let uniqueIdentifier: UUID; let name: String; let serviceType: String
    let associatedServiceType: String?; let characteristics: [HMCharacteristic]
    init(_ n: Int, _ name: String, type: String, associated: String? = nil, chars: [HMCharacteristic]) {
        uniqueIdentifier = fixtureID(n); self.name = name; serviceType = type
        associatedServiceType = associated; characteristics = chars
    }
}
final class HMAccessory {
    let uniqueIdentifier: UUID; let name: String; let services: [HMService]
    let category: HMCategory; weak var room: HMRoom?
    let manufacturer: String? = nil; let isReachable = true; let matterNodeID: UInt64? = nil
    init(_ n: Int, _ name: String, services: [HMService]) {
        uniqueIdentifier = fixtureID(n); self.name = name; self.services = services
        category = HMCategory(categoryType: HMAccessoryCategoryTypeSwitch)
    }
}
final class HMRoom {
    let uniqueIdentifier = fixtureID(100); let name = "Dining Room"
    var accessories: [HMAccessory]
    init(_ accessories: [HMAccessory]) { self.accessories = accessories; for a in accessories { a.room = self } }
}
struct HMZone { let name: String; let rooms: [HMRoom] }
final class HMHome {
    let uniqueIdentifier = fixtureID(200); let name = "Synthetic Home"; let isPrimary = true
    let rooms: [HMRoom]; let zones: [HMZone] = []; var accessories: [HMAccessory] { rooms.flatMap(\.accessories) }
    init(_ rooms: [HMRoom]) { self.rooms = rooms }
}
final class HomeClawConfig: @unchecked Sendable {
    static let shared = HomeClawConfig()
    var filterMode = "all"; var allowedIDs: Set<String>? = nil; var defaultHomeID: String? = nil
    func formatTemperature(_ number: Double) -> String { String(number) }
}
struct CharacteristicCache {
    let isStale = false
    // Deliberately contradicts kitchen's real last-known service value. Services
    // must not inherit a collapsed accessory-wide cache value.
    func cachedState(for id: String) -> [String: String] { ["power": "true"] }
}
struct BridgeMetadata {
    init(homes: [HMHome], isAccessoryVisible: (HMAccessory) -> Bool) {}
    func bridgeSummary(for accessory: HMAccessory) -> [String: Any]? { nil }
    func bridgedAccessoryIDs(for accessory: HMAccessory) -> [String] { [] }
}
enum DemoFixtures {
    static func accessorySummaries() -> [[String: Any]] { [] }
    static func roomSummaries() -> [[String: Any]] { [] }
    static func searchAccessories(query: String, category: String?) -> [[String: Any]] { [] }
    static func deviceMap() -> [String: Any] { [:] }
}
