import ArgumentParser
import Foundation
import SwiftTUI

/// `homeclaw-cli ui` — full-screen interactive HomeKit browser.
///
/// Slice 1: rooms + accessories tree, fetched once from the running
/// HomeClaw app. Each accessory row is a focusable Button so arrow keys
/// move focus (and scroll the view) — without focusable controls,
/// SwiftTUI's ScrollView can't intercept arrows and they leak as raw
/// escape codes. Pressing Enter on a row is a no-op for now (slice 2
/// will toggle accessories). Quit with `q` or Ctrl-C.
///
/// Full UX plan in issue #53.
struct Ui: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "Launch the interactive TUI for HomeKit control"
    )

    func run() throws {
        let initial = try fetchInitialState()
        Application(rootView: HomeClawTUIView(initialState: initial)).start()
    }

    private func fetchInitialState() throws -> HomeClawTUIView.HomeKitState {
        // listRooms returns rooms with their accessories embedded — exactly what
        // the tree view needs in a single round-trip.
        let response = try SocketClient.send(command: "list_rooms", args: nil)
        guard response.success else {
            throw ValidationError(response.error ?? "Failed to load HomeKit data")
        }

        let rooms = (response.data?.value as? [[String: Any]]) ?? []
        let modelRooms: [HomeClawTUIView.RoomNode] = rooms.map { dict in
            let accDicts = (dict["accessories"] as? [[String: Any]]) ?? []
            let accessories: [HomeClawTUIView.AccessoryNode] = accDicts.map { acc in
                let state = (acc["state"] as? [String: String]) ?? [:]
                return HomeClawTUIView.AccessoryNode(
                    id: acc["id"] as? String ?? UUID().uuidString,
                    name: acc["name"] as? String ?? "Unknown",
                    category: acc["category"] as? String ?? "other",
                    state: state
                )
            }
            return HomeClawTUIView.RoomNode(
                id: dict["id"] as? String ?? UUID().uuidString,
                name: dict["name"] as? String ?? "Unknown",
                accessories: accessories
            )
        }

        return HomeClawTUIView.HomeKitState(rooms: modelRooms)
    }
}

// MARK: - SwiftTUI views

private struct HomeClawTUIView: View {
    struct AccessoryNode: Identifiable {
        let id: String
        let name: String
        let category: String
        let state: [String: String]

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

        /// Whether the state should render in bold. Bold reads as "active /
        /// attention-worthy" (light is on, lock is unlocked, motion detected,
        /// thermostat is heating/cooling) vs. quiet ambient states.
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

        /// Color for the state summary text (separate from `statusColor` for
        /// the leading dot — they happen to match in most cases, but this
        /// gives us room to differentiate when needed).
        var stateColor: Color {
            // Power: on → category color, off → dim
            if let power = state["power_state"]?.lowercased() {
                if power == "on" { return statusColor }
                return .brightBlack
            }
            // Locks: green when locked, red when unlocked
            if let lock = state["lock_current_state"]?.lowercased() {
                if lock == "locked" || lock == "secured" { return .green }
                if lock == "unlocked" || lock == "unsecured" { return .brightRed }
                return .yellow
            }
            // Heating/cooling mode → red for heat, cyan for cool, yellow for auto, dim for off
            if let mode = state["current_heating_cooling_state"]?.lowercased() {
                switch mode {
                case "heat": return .brightRed
                case "cool": return .brightCyan
                case "auto": return .brightYellow
                default: return .brightBlack
                }
            }
            // Motion alert
            if let motion = state["motion_detected"]?.lowercased(),
               motion == "yes" || motion == "true" || motion == "1" {
                return .brightRed
            }
            // Temperatures, positions, sensor values — informational
            if state["current_temperature"] != nil { return .cyan }
            if state["current_position"] != nil { return .brightBlack }
            return .brightBlack
        }
    }

    struct RoomNode: Identifiable {
        let id: String
        let name: String
        let accessories: [AccessoryNode]
    }

    struct HomeKitState {
        let rooms: [RoomNode]
        var totalAccessoryCount: Int { rooms.reduce(0) { $0 + $1.accessories.count } }
    }

    let initialState: HomeKitState

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
            Text("\(initialState.rooms.count) rooms")
                .foregroundColor(.brightBlack)
            Text("·").foregroundColor(.brightBlack)
            Text("\(initialState.totalAccessoryCount) accessories")
                .foregroundColor(.brightBlack)
        }
        .padding(.bottom, 1)
    }

    private var tree: some View {
        ScrollView {
            VStack(alignment: .leading) {
                ForEach(Array(initialState.rooms.enumerated()), id: \.element.id) { _, room in
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
        // Wrapping the row in a Button gives SwiftTUI's ScrollView a focusable
        // child to track — that's what enables arrow-key scrolling. Pressing
        // Enter is a no-op for now (slice 2 wires up toggle/control).
        Button(action: {}) {
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
        // Active states (light On, lock Unlocked, motion, heat/cool running)
        // render in bold + meaningful color. Quiet states (Off, idle) stay dim.
        if accessory.stateIsActive {
            Text(accessory.stateSummary).bold().foregroundColor(accessory.stateColor)
        } else {
            Text(accessory.stateSummary).foregroundColor(accessory.stateColor)
        }
    }

    private var footer: some View {
        // SwiftTUI hardcodes Ctrl-D (EOT) as the only application-level quit
        // key — q can't be intercepted without forking the library, so the
        // footer documents what actually works. Enter triggers the focused
        // accessory's Button action (slice 2 will toggle / open details).
        HStack {
            footerKey("^D", "quit")
            footerKey("↑↓", "navigate")
            footerKey("Enter", "details")
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

    /// Truncate to width-1 + `…`, or pad with trailing spaces. Uses
    /// extended-grapheme count so accented chars / emoji don't break alignment.
    private static func padded(_ s: String, to width: Int) -> String {
        let count = s.count
        if count > width {
            return String(s.prefix(width - 1)) + "…"
        }
        return s + String(repeating: " ", count: width - count)
    }
}
