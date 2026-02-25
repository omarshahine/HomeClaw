import ArgumentParser
import Foundation

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List HomeKit accessories"
    )

    @Option(name: .long, help: "Filter by room name")
    var room: String?

    @Option(name: .long, help: "Filter by category (e.g., lightbulb, lock, thermostat)")
    var category: String?

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: String] = [:]
        if let room { args["room"] = room }

        let response = try SocketClient.send(command: "list_accessories", args: args.isEmpty ? nil : args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if json {
            printJSON(response.data?.value)
            return
        }

        guard let accessories = response.data?.value as? [[String: Any]] else {
            print("No accessories found.")
            return
        }

        // Filter by category client-side if needed
        var filtered = accessories
        if let category {
            filtered = filtered.filter {
                ($0["category"] as? String)?.lowercased() == category.lowercased()
            }
        }

        if filtered.isEmpty {
            print("No accessories found.")
            return
        }

        for accessory in filtered {
            let name = accessory["name"] as? String ?? "Unknown"
            let category = accessory["category"] as? String ?? "unknown"
            let room = accessory["room"] as? String ?? "No Room"
            let reachable = (accessory["reachable"] as? Bool ?? false) ? "+" : "-"

            var stateStr = ""
            if let state = accessory["state"] as? [String: String] {
                stateStr = state.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            }

            print("\(reachable) \(name) [\(category)] in \(room)\(stateStr.isEmpty ? "" : " — \(stateStr)")")
        }
    }
}
