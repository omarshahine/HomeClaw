import ArgumentParser
import Foundation
import SwiftTUI

/// `homeclaw-cli ui` — full-screen interactive HomeKit browser.
///
/// First slice: rooms + accessories tree, fetched once from the running
/// HomeClaw app via the existing socket. Navigation with arrow keys, quit
/// with `q`. See issue #53 for the full UX plan (detail pane, event log,
/// scene picker, live updates, search).
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

        /// Compact one-line state summary for the tree row (e.g. "[On]", "72°F").
        var stateSummary: String {
            if let power = state["power_state"] { return "[\(power)]" }
            if let temp = state["current_temperature"] { return "\(temp)°F" }
            if let lock = state["lock_current_state"] { return lock }
            if let pos = state["current_position"] { return "\(pos)%" }
            if let motion = state["motion_detected"] { return motion == "Yes" ? "Motion" : "Idle" }
            if let speed = state["rotation_speed"] { return "\(speed)%" }
            return ""
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
            Divider()
            tree
            Spacer()
            Divider()
            footer
        }
        .padding(1)
    }

    private var header: some View {
        HStack {
            Text("HomeClaw").bold()
            Spacer()
            Text("\(initialState.rooms.count) rooms · \(initialState.totalAccessoryCount) accessories")
                .foregroundColor(.gray)
        }
    }

    private var tree: some View {
        ScrollView {
            ForEach(initialState.rooms) { room in
                VStack(alignment: .leading) {
                    Text("▼ \(room.name) (\(room.accessories.count))")
                        .bold()
                    ForEach(room.accessories) { accessory in
                        accessoryRow(accessory)
                    }
                }
                .padding(.bottom, 1)
            }
        }
    }

    private func accessoryRow(_ accessory: AccessoryNode) -> some View {
        HStack {
            Text("  \(accessory.name)")
            Spacer()
            Text(accessory.stateSummary).foregroundColor(.gray)
        }
    }

    private var footer: some View {
        Text("q to quit · arrows to navigate · (slice 1: read-only tree)")
            .foregroundColor(.gray)
    }
}
