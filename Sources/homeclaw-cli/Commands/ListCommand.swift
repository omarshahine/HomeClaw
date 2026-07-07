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

    /// Filters accessories by category (case-insensitive). Returns the input unchanged
    /// when `category` is nil. Pure helper so the filter behaves identically for text
    /// and JSON output (issue #72).
    static func filterByCategory(_ accessories: [[String: Any]], category: String?) -> [[String: Any]] {
        guard let category else { return accessories }
        return accessories.filter {
            ($0["category"] as? String)?.lowercased() == category.lowercased()
        }
    }

    func run() throws {
        var args: [String: String] = [:]
        if let room { args["room"] = room }

        let response = try SocketClient.send(command: "list_accessories", args: args.isEmpty ? nil : args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        // If there's no category filter, JSON output can pass through the raw payload.
        if shouldOutputJSON(json), category == nil {
            printJSON(response.data?.value)
            return
        }

        guard let accessories = response.data?.value as? [[String: Any]] else {
            if shouldOutputJSON(json) {
                printJSON([[String: Any]]())
            } else {
                print("No accessories found.")
            }
            return
        }

        // Filter by category client-side if needed. Applies to both JSON and text
        // output so the filter behaves consistently (issue #72).
        let filtered = Self.filterByCategory(accessories, category: category)

        if shouldOutputJSON(json) {
            printJSON(filtered)
            return
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
            let bridgeStr = bridgeDisplayName(in: accessory).map { " via \($0)" } ?? ""

            print("\(reachable) \(name) [\(category)] in \(room)\(bridgeStr)\(stateStr.isEmpty ? "" : " — \(stateStr)")")
        }
    }
}
