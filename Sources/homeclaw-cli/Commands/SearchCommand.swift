import ArgumentParser
import Foundation

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search accessories by name, room, or category"
    )

    @Argument(help: "Search query")
    var query: String

    @Option(name: .long, help: "Filter by category")
    var category: String?

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: String] = ["query": query]
        if let category { args["category"] = category }

        let response = try SocketClient.send(command: "search", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if json {
            printJSON(response.data?.value)
            return
        }

        guard let accessories = response.data?.value as? [[String: Any]] else {
            print("No results.")
            return
        }

        if accessories.isEmpty {
            print("No results for '\(query)'.")
            return
        }

        print("Found \(accessories.count) result(s):")
        for accessory in accessories {
            let name = accessory["name"] as? String ?? "Unknown"
            let category = accessory["category"] as? String ?? "unknown"
            let room = accessory["room"] as? String ?? "No Room"
            print("  \(name) [\(category)] in \(room)")
        }
    }
}
