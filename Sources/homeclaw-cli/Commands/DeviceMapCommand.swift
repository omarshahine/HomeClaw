import ArgumentParser
import Foundation

struct DeviceMapCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-map",
        abstract: "Show LLM-optimized device map with semantic types and aliases"
    )

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        let response = try SocketClient.send(command: "device_map")

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if json {
            printJSON(response.data?.value)
            return
        }

        guard let data = response.data?.value as? [String: Any] else {
            print("No data returned.")
            return
        }

        // Stats
        if let stats = data["stats"] as? [String: Any] {
            let total = stats["total"] as? Int ?? 0
            let reachable = stats["reachable"] as? Int ?? 0
            print("Device Map (\(total) devices, \(reachable) reachable)")

            if let byType = stats["by_semantic_type"] as? [String: Int] {
                let sorted = byType.sorted { $0.value > $1.value }
                for (type, count) in sorted {
                    print("  \(type): \(count)")
                }
            }
            print()
        }

        if let note = data["disambiguation_note"] as? String {
            print("Note: \(note)")
            print()
        }

        // Home → Zone → Room → Device tree
        guard let homes = data["homes"] as? [[String: Any]] else { return }

        for home in homes {
            let homeName = home["name"] as? String ?? "Unknown"
            print(homeName)

            guard let zones = home["zones"] as? [[String: Any]] else { continue }

            for zone in zones {
                let zoneName = zone["name"] as? String ?? "Unknown"
                print("  \(zoneName)")

                guard let rooms = zone["rooms"] as? [[String: Any]] else { continue }

                for room in rooms {
                    let roomName = room["name"] as? String ?? "Unknown"
                    let devices = room["devices"] as? [[String: Any]] ?? []
                    print("    \(roomName) (\(devices.count) devices)")

                    for device in devices {
                        let name = device["name"] as? String ?? "?"
                        let semanticType = device["semantic_type"] as? String ?? "?"
                        let summary = device["state_summary"] as? String ?? ""
                        let displayName = device["display_name"] as? String
                        let reachable = device["reachable"] as? Bool ?? false

                        let nameStr = displayName ?? name
                        let prefix = reachable ? "+" : "-"
                        let stateStr =
                            summary.isEmpty || summary == "unknown" ? "" : " — \(summary)"
                        print("      \(prefix) \(nameStr) [\(semanticType)]\(stateStr)")
                    }
                }
            }
        }
    }
}
