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

    @Flag(name: .long, help: "Skip live characteristic reads; return last-known + static values only (fast — ideal for serial number / model / firmware sweeps)")
    var noRefresh = false

    func run() throws {
        if let err = validateInput(accessory, label: "accessory") { throw ValidationError(err) }
        var args: [String: String] = ["id": accessory]
        if noRefresh { args["refresh"] = "false" }
        let response = try SocketClient.send(command: "get_accessory", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if shouldOutputJSON(json) {
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
        if let bridge = bridgeDisplayName(in: detail) {
            print("  Bridge:    \(bridge)")
        }
        if let bridgedAccessoryCount = detail["bridged_accessory_count"] as? Int {
            print("  Bridged:   \(bridgedAccessoryCount) accessory(ies)")
        }
        if detail["refreshed"] as? Bool == false {
            print("  Note:      --no-refresh — static + last-known values only (dynamic state not live-read)")
        }

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
