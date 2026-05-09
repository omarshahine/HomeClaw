import ArgumentParser
import Foundation
import SwiftTUI

/// `homeclaw-cli ui` — full-screen interactive HomeKit browser.
///
/// What works in this version:
/// - Tree of rooms + accessories from the running HomeClaw app
/// - Live arrow-key navigation between accessory rows
/// - Enter on a focused row toggles the accessory (lights/switches/
///   outlets/fans flip power_state, locks flip lock_target_state, blinds
///   flip target_position between 0 and 100)
/// - Optimistic local update + socket refetch after each toggle
/// - Color-coded state values (On in category color, Off dim, Locked
///   green, Unlocked red, etc.)
/// - Ctrl-D to quit (SwiftTUI hardcodes EOT — `q` cannot be intercepted
///   without forking the library)
///
/// Out of scope per SwiftTUI's app-level key-handler limits:
/// - Scene picker overlay (`s`)
/// - Search (`/`)
/// - Help overlay (`?`)
/// These would require either forking SwiftTUI or switching to a more
/// flexible TUI framework (TermKit, Bubble Tea). See issue #53.
struct Ui: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "Launch the interactive TUI for HomeKit control"
    )

    func run() throws {
        let initialRooms = try fetchRooms()
        let state = TUIHomeState(rooms: initialRooms)
        Application(rootView: HomeClawTUIView(state: state)).start()
    }

    private func fetchRooms() throws -> [RoomNode] {
        let response = try SocketClient.send(command: "list_rooms", args: nil)
        guard response.success else {
            throw ValidationError(response.error ?? "Failed to load HomeKit data")
        }
        return Self.parseRooms((response.data?.value as? [[String: Any]]) ?? [])
    }

    /// Shared parser used by both initial fetch and post-toggle refetch.
    static func parseRooms(_ rooms: [[String: Any]]) -> [RoomNode] {
        return rooms.map { dict in
            let accDicts = (dict["accessories"] as? [[String: Any]]) ?? []
            let accessories: [AccessoryNode] = accDicts.map { acc in
                let state = (acc["state"] as? [String: String]) ?? [:]
                return AccessoryNode(
                    id: acc["id"] as? String ?? UUID().uuidString,
                    name: acc["name"] as? String ?? "Unknown",
                    category: acc["category"] as? String ?? "other",
                    state: state
                )
            }
            return RoomNode(
                id: dict["id"] as? String ?? UUID().uuidString,
                name: dict["name"] as? String ?? "Unknown",
                accessories: accessories
            )
        }
    }
}

// MARK: - Models (file-level so TUIHomeState can hold them)

struct AccessoryNode: Identifiable {
    let id: String
    let name: String
    let category: String
    var state: [String: String]

    /// Compact one-line state summary. Values arrive from the socket
    /// already formatted by CharacteristicMapper (e.g. "63°F", "locked"),
    /// so this picks the most informative one and tunes the casing.
    var stateSummary: String {
        if let power = state["power_state"], !power.isEmpty {
            return power.capitalized
        }
        if let temp = state["current_temperature"], !temp.isEmpty, temp != "--" {
            return temp
        }
        if let lock = state["lock_current_state"], !lock.isEmpty {
            return lock.capitalized
        }
        if let mode = state["current_heating_cooling_state"], !mode.isEmpty {
            return mode.capitalized
        }
        if let pos = state["current_position"], !pos.isEmpty, pos != "--" {
            return "\(pos)%"
        }
        if let motion = state["motion_detected"], !motion.isEmpty {
            let on = motion.lowercased()
            if on == "yes" || on == "true" || on == "1" { return "Motion" }
            return ""
        }
        if let speed = state["rotation_speed"], !speed.isEmpty, speed != "--" {
            return "\(speed)%"
        }
        return ""
    }

    var statusGlyph: String {
        if let power = state["power_state"]?.lowercased() {
            return power == "on" ? "●" : "○"
        }
        if let lock = state["lock_current_state"]?.lowercased() {
            if lock == "locked" || lock == "secured" { return "●" }
            if lock == "unlocked" || lock == "unsecured" { return "◐" }
            return "○"
        }
        if let motion = state["motion_detected"]?.lowercased() {
            if motion == "yes" || motion == "true" || motion == "1" { return "●" }
            return "○"
        }
        if state["current_temperature"] != nil { return "◐" }
        return "○"
    }

    var statusColor: Color {
        if let power = state["power_state"]?.lowercased(), power == "on" {
            switch category {
            case "lightbulb": return .yellow
            case "outlet", "switch": return .cyan
            case "fan": return .blue
            default: return .green
            }
        }
        if let lock = state["lock_current_state"]?.lowercased() {
            if lock == "locked" || lock == "secured" { return .green }
            if lock == "unlocked" || lock == "unsecured" { return .red }
            return .yellow
        }
        if let motion = state["motion_detected"]?.lowercased(),
           motion == "yes" || motion == "true" || motion == "1" {
            return .red
        }
        if state["current_temperature"] != nil { return .cyan }
        return .brightBlack
    }

    var stateIsActive: Bool {
        if let power = state["power_state"]?.lowercased() { return power == "on" }
        if let lock = state["lock_current_state"]?.lowercased() {
            return lock == "unlocked" || lock == "unsecured"
        }
        if let motion = state["motion_detected"]?.lowercased() {
            return motion == "yes" || motion == "true" || motion == "1"
        }
        if let mode = state["current_heating_cooling_state"]?.lowercased() {
            return mode != "off"
        }
        return false
    }

    var stateColor: Color {
        if let power = state["power_state"]?.lowercased() {
            if power == "on" { return statusColor }
            return .brightBlack
        }
        if let lock = state["lock_current_state"]?.lowercased() {
            if lock == "locked" || lock == "secured" { return .green }
            if lock == "unlocked" || lock == "unsecured" { return .brightRed }
            return .yellow
        }
        if let mode = state["current_heating_cooling_state"]?.lowercased() {
            switch mode {
            case "heat": return .brightRed
            case "cool": return .brightCyan
            case "auto": return .brightYellow
            default: return .brightBlack
            }
        }
        if let motion = state["motion_detected"]?.lowercased(),
           motion == "yes" || motion == "true" || motion == "1" {
            return .brightRed
        }
        if state["current_temperature"] != nil { return .cyan }
        return .brightBlack
    }

    /// What characteristic + value to send on Enter, given the current state.
    /// Returns nil for accessories whose toggle behavior isn't well-defined
    /// (sensors, thermostats — those need slice 3).
    var toggleTarget: (characteristic: String, value: String)? {
        if let power = state["power_state"]?.lowercased() {
            return ("power_state", power == "on" ? "off" : "on")
        }
        if let lock = state["lock_current_state"]?.lowercased() {
            if lock == "locked" || lock == "secured" {
                return ("lock_target_state", "unlocked")
            }
            return ("lock_target_state", "locked")
        }
        if let posStr = state["current_position"], let pos = Int(posStr) {
            return ("target_position", pos > 50 ? "0" : "100")
        }
        return nil
    }
}

struct RoomNode: Identifiable {
    let id: String
    let name: String
    var accessories: [AccessoryNode]
}

// MARK: - State management

/// Holds the live tree of rooms/accessories and handles toggle round-trips.
/// `@Published rooms` triggers a SwiftTUI re-render whenever state changes,
/// so optimistic updates show up instantly and the post-control refetch
/// reconciles with what HomeKit actually reports back.
///
/// SwiftTUI runs on DispatchQueue.main; Button actions call into here on
/// the main thread. Socket round-trips happen on a background queue, with
/// state mutations bounced back to main. We mark this `@unchecked Sendable`
/// because thread-safety is handled by the explicit DispatchQueue hops
/// rather than by the actor system.
final class TUIHomeState: ObservableObject, @unchecked Sendable {
    @Published var rooms: [RoomNode]

    init(rooms: [RoomNode]) {
        self.rooms = rooms
    }

    var totalAccessoryCount: Int { rooms.reduce(0) { $0 + $1.accessories.count } }

    /// Toggle the accessory with the given id. Looks up the current state
    /// at call time — never trusts a captured `accessory` snapshot, since
    /// SwiftTUI Button closures capture by value and would always see the
    /// initial state, breaking the second and subsequent toggles.
    /// Optimistically flips the local state for instant feedback, then
    /// sends the control command and refetches truth.
    func toggle(accessoryId: String) {
        guard let current = findAccessory(id: accessoryId),
              let target = current.toggleTarget
        else { return }
        applyOptimisticUpdate(accessoryId: accessoryId, target: target)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = try? SocketClient.send(command: "control", args: [
                "id": accessoryId,
                "characteristic": target.characteristic,
                "value": target.value,
            ])
            DispatchQueue.main.async { self?.refetch() }
        }
    }

    private func findAccessory(id: String) -> AccessoryNode? {
        for room in rooms {
            if let match = room.accessories.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    /// Re-pull the room/accessory tree from the running app. Used after
    /// every toggle, and could later be hooked to a periodic timer or to
    /// a `homeKitMenuDataDidChange` push for true live updates.
    func refetch() {
        guard let response = try? SocketClient.send(command: "list_rooms", args: nil),
              response.success,
              let dicts = response.data?.value as? [[String: Any]]
        else { return }
        rooms = Ui.parseRooms(dicts)
    }

    /// Mutate the local rooms array to reflect a toggle the user just made.
    /// Maps target-side characteristics to current-side state keys
    /// (`lock_target_state` → `lock_current_state`, `target_position` →
    /// `current_position`) and uses the same casing CharacteristicMapper
    /// would have produced server-side ("on" → "On", "locked" → "locked").
    private func applyOptimisticUpdate(
        accessoryId: String,
        target: (characteristic: String, value: String)
    ) {
        rooms = rooms.map { room in
            var newRoom = room
            newRoom.accessories = room.accessories.map { acc in
                guard acc.id == accessoryId else { return acc }
                var newAcc = acc
                let (key, mappedValue) = Self.optimisticStateChange(target: target)
                newAcc.state[key] = mappedValue
                return newAcc
            }
            return newRoom
        }
    }

    private static func optimisticStateChange(
        target: (characteristic: String, value: String)
    ) -> (key: String, value: String) {
        switch target.characteristic {
        case "power_state":
            return ("power_state", target.value.capitalized)  // "on" → "On"
        case "lock_target_state":
            return ("lock_current_state", target.value)  // "locked" / "unlocked"
        case "target_position":
            return ("current_position", target.value)
        default:
            return (target.characteristic, target.value)
        }
    }
}

// MARK: - Views

struct HomeClawTUIView: View {
    @ObservedObject var state: TUIHomeState

    /// Width of the left-aligned name column. Long names truncate with `…`,
    /// short names pad with trailing spaces so the state column lines up.
    private static let nameColumnWidth = 32

    var body: some View {
        VStack(alignment: .leading) {
            header
            tree
                .border(.rounded)
            footer
        }
        .padding(1)
    }

    private var header: some View {
        HStack {
            Text("🦞 ").foregroundColor(.brightYellow)
            Text("HomeClaw").bold().foregroundColor(.cyan)
            Spacer()
            Text("\(state.rooms.count) rooms")
                .foregroundColor(.brightBlack)
            Text("·").foregroundColor(.brightBlack)
            Text("\(state.totalAccessoryCount) accessories")
                .foregroundColor(.brightBlack)
        }
        .padding(.bottom, 1)
    }

    private var tree: some View {
        ScrollView {
            VStack(alignment: .leading) {
                ForEach(Array(state.rooms.enumerated()), id: \.element.id) { _, room in
                    roomSection(room)
                }
            }
            .padding(1)
        }
    }

    private func roomSection(_ room: RoomNode) -> some View {
        VStack(alignment: .leading) {
            HStack(spacing: 0) {
                Text("▾ ").foregroundColor(.brightBlack)
                Text(room.name).bold()
                Text(" (\(room.accessories.count))").foregroundColor(.brightBlack)
            }
            ForEach(Array(room.accessories.enumerated()), id: \.element.id) { idx, accessory in
                accessoryRow(accessory, isLast: idx == room.accessories.count - 1)
            }
        }
        .padding(.bottom, 1)
    }

    private func accessoryRow(_ accessory: AccessoryNode, isLast: Bool) -> some View {
        // Wrapping the row in a Button gives SwiftTUI's ScrollView a
        // focusable child to track and lets Enter trigger toggle. We pass
        // only the id so the toggle reads current state rather than a
        // captured snapshot.
        let accessoryId = accessory.id
        return Button(action: { state.toggle(accessoryId: accessoryId) }) {
            HStack(spacing: 0) {
                Text("  ").foregroundColor(.brightBlack)
                Text(isLast ? "└─" : "├─").foregroundColor(.brightBlack)
                Text(" ")
                Text(accessory.statusGlyph).foregroundColor(accessory.statusColor)
                Text(" ")
                Text(Self.padded(accessory.name, to: Self.nameColumnWidth))
                stateText(accessory)
            }
        }
    }

    @ViewBuilder
    private func stateText(_ accessory: AccessoryNode) -> some View {
        if accessory.stateIsActive {
            Text(accessory.stateSummary).bold().foregroundColor(accessory.stateColor)
        } else {
            Text(accessory.stateSummary).foregroundColor(accessory.stateColor)
        }
    }

    private var footer: some View {
        HStack {
            footerKey("^D", "quit")
            footerKey("↑↓", "navigate")
            footerKey("Enter", "toggle")
            Spacer()
        }
        .padding(.top, 1)
    }

    private func footerKey(_ key: String, _ label: String) -> some View {
        HStack(spacing: 0) {
            Text(key).bold().foregroundColor(.brightYellow)
            Text(" ")
            Text(label).foregroundColor(.brightBlack)
            Text("  ")
        }
    }

    /// Truncate to width-1 + `…`, or pad with trailing spaces.
    private static func padded(_ s: String, to width: Int) -> String {
        let count = s.count
        if count > width {
            return String(s.prefix(width - 1)) + "…"
        }
        return s + String(repeating: " ", count: width - count)
    }
}
