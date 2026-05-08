import ArgumentParser
import Foundation
import SwiftTUI

/// `homeclaw-cli ui` — full-screen interactive HomeKit browser.
///
/// First slice: rooms + accessories tree, fetched once from the running
/// HomeClaw app via the existing socket. Quit with `q`. See issue #53 for
/// the full UX plan (detail pane, event log, scene picker, live updates,
/// search).
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
        /// so this just picks the most informative one and lightly cosmetic-
        /// tunes the casing.
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

        /// Single-glyph status indicator. Filled for "active" states (light
        /// on, lock locked, motion detected), hollow for off/idle.
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
            // Sensors with a current value count as active.
            if state["current_temperature"] != nil { return "◐" }
            return "○"
        }

        var statusColor: Color {
            // On/off coloring for actuators
            if let power = state["power_state"]?.lowercased(), power == "on" {
                switch category {
                case "lightbulb": return .yellow
                case "outlet", "switch": return .cyan
                case "fan": return .blue
                default: return .green
                }
            }
            // Lock states have their own semantics
            if let lock = state["lock_current_state"]?.lowercased() {
                if lock == "locked" || lock == "secured" { return .green }
                if lock == "unlocked" || lock == "unsecured" { return .red }
                return .yellow
            }
            // Active motion
            if let motion = state["motion_detected"]?.lowercased(),
               motion == "yes" || motion == "true" || motion == "1" {
                return .red
            }
            // Read-only sensors
            if state["current_temperature"] != nil { return .cyan }
            // Off / idle / unknown — dim
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
            HStack {
                Text("▾ ").foregroundColor(.brightBlack)
                Text(room.name).bold()
                Text("(\(room.accessories.count))").foregroundColor(.brightBlack)
            }
            ForEach(Array(room.accessories.enumerated()), id: \.element.id) { idx, accessory in
                accessoryRow(accessory, isLast: idx == room.accessories.count - 1)
            }
        }
        .padding(.bottom, 1)
    }

    private func accessoryRow(_ accessory: AccessoryNode, isLast: Bool) -> some View {
        HStack {
            Text("  \(isLast ? "└─" : "├─") ").foregroundColor(.brightBlack)
            Text(accessory.statusGlyph).foregroundColor(accessory.statusColor)
            Text(" \(accessory.name)")
            Spacer()
            Text(accessory.stateSummary).foregroundColor(.brightBlack)
            Text("  ")
        }
    }

    private var footer: some View {
        HStack {
            footerKey("q", "quit")
            footerKey("↑↓", "scroll")
            Text("·").foregroundColor(.brightBlack)
            Text("slice 1: read-only").foregroundColor(.brightBlack)
            Spacer()
        }
        .padding(.top, 1)
    }

    private func footerKey(_ key: String, _ label: String) -> some View {
        HStack {
            Text(key).bold().foregroundColor(.brightYellow)
            Text(label).foregroundColor(.brightBlack)
        }
    }
}
