import Foundation

// In-memory API-shaped doubles only. This executable does not import HomeKit.
let HMActionSetTypeWakeUp = "fixture.wake"
let HMActionSetTypeSleep = "fixture.sleep"
let HMActionSetTypeHomeDeparture = "fixture.leave"
let HMActionSetTypeHomeArrival = "fixture.arrive"

final class HMRoom {
    let name: String
    var accessories: [HMAccessory] = []
    init(_ name: String) { self.name = name }
}
final class HMAccessory {
    let uniqueIdentifier: UUID
    let name: String
    let category: String
    let room: HMRoom?
    init(_ n: Int, _ name: String, room: HMRoom?, category: String = "lightbulb") {
        uniqueIdentifier = fixtureID(n); self.name = name; self.room = room; self.category = category
    }
}
func fixtureID(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}
final class HMService { var accessory: HMAccessory?; init(_ accessory: HMAccessory) { self.accessory = accessory } }
final class HMCharacteristic { var service: HMService?; init(_ accessory: HMAccessory) { service = HMService(accessory) } }
final class HMCharacteristicWriteAction<T>: NSObject {
    let characteristic: HMCharacteristic
    init(_ accessory: HMAccessory) { characteristic = HMCharacteristic(accessory) }
}
final class HMActionSet {
    let uniqueIdentifier: UUID
    var name: String
    let actionSetType: String
    var actions: [NSObject]
    let lastExecutionDate: Date? = nil
    init(_ n: Int, _ name: String, type: String = "fixture.user", accessories: [HMAccessory]) {
        uniqueIdentifier = fixtureID(n); self.name = name; actionSetType = type
        actions = accessories.map { HMCharacteristicWriteAction<NSCopying>($0) }
    }
}
final class HMTrigger { let actionSets: [HMActionSet]; init(_ sets: [HMActionSet]) { actionSets = sets } }
final class HMHome {
    let uniqueIdentifier = fixtureID(1)
    let name = "Synthetic Home"
    let rooms: [HMRoom]
    var actionSets: [HMActionSet]
    var triggers: [HMTrigger] = []
    var accessories: [HMAccessory] = []
    var executions: [UUID] = []
    @MainActor func executeActionSet(_ scene: HMActionSet) async throws { executions.append(scene.uniqueIdentifier) }
    init(rooms: [HMRoom], scenes: [HMActionSet]) { self.rooms = rooms; actionSets = scenes }
}
@MainActor final class HomeClawConfig {
    static let shared = HomeClawConfig()
    var filterMode = "all"
    var allowedIDs: Set<String>? = nil
}
struct FixtureCache {
    func cachedState(for id: String) -> [String: String] { ["power": "false"] }
}
@MainActor struct BridgeMetadata {
    init(homes: [HMHome], isAccessoryVisible: (HMAccessory) -> Bool) {}
    func bridgeSummary(for accessory: HMAccessory) -> [String: Any]? { nil }
    func bridgedAccessoryIDs(for accessory: HMAccessory) -> [String] { [] }
}
enum DemoFixtures {
    static let homeName = "Unused demo"
    static var sceneSummaries: [[String: Any]] { [] }
    static func menuData() -> [String: Any] { [:] }
}
@MainActor final class WebhookCircuitBreaker {
    enum State: String { case closed }
    static let shared = WebhookCircuitBreaker()
    let state = State.closed
    let softTripCount = 0
    let remainingCooldownSeconds = 0
    let totalDroppedCount = 0
}

struct FixtureLogger { func info(_ message: String) {} }
enum AppLogger { static let homekit = FixtureLogger() }
@MainActor final class HomeEventLogger {
    static let shared = HomeEventLogger()
    func logSceneTriggered(sceneID: String, sceneName: String, homeName: String, homeID: String) {}
}
