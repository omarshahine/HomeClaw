import ArgumentParser
import Foundation

struct Get: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Get detailed info about an accessory"
    )

    @Argument(help: "Accessory name or UUID")
    var accessory: String

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        let response = try SocketClient.send(command: "get_accessory", args: ["id": accessory])

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if json {
            printJSON(response.data?.value)
            return
        }

        guard let detail = response.data?.value as? [String: Any] else {
            print("Accessory not found.")
            return
        }

        let name = detail["name"] as? String ?? "Unknown"
        let category = detail["category"] as? String ?? "unknown"
        let room = detail["room"] as? String ?? "No Room"
        let reachable = (detail["reachable"] as? Bool ?? false) ? "Yes" : "No"

        print("\(name)")
        print("  Category:  \(category)")
        print("  Room:      \(room)")
        print("  Reachable: \(reachable)")

        if let services = detail["services"] as? [[String: Any]] {
            for service in services {
                let serviceName = service["name"] as? String ?? "Unknown Service"
                guard let chars = service["characteristics"] as? [[String: Any]] else { continue }

                print("  [\(serviceName)]")
                for char in chars {
                    let charName = char["name"] as? String ?? "?"
                    let value = char["value"] as? String ?? "nil"
                    let writable = (char["writable"] as? Bool ?? false) ? " (writable)" : ""
                    print("    \(charName): \(value)\(writable)")
                }
            }
        }
    }
}
