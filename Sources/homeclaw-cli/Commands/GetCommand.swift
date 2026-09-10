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

    static func refreshContractError(
        noRefresh: Bool,
        detail: [String: Any]
    ) -> String? {
        guard let refreshed = detail["refreshed"] as? Bool,
              let attempted = detail["read_attempted"] as? Int,
              let succeeded = detail["read_succeeded"] as? Int
        else {
            return "HomeClaw response is missing valid freshness metadata"
        }

        if noRefresh {
            return refreshed == false && attempted == 0 && succeeded == 0
                ? nil
                : "HomeClaw returned fresh-read metadata for --no-refresh"
        }

        guard refreshed, attempted > 0, succeeded == attempted else {
            return "HomeClaw live refresh failed; values may be last-known"
        }
        guard let services = detail["services"] as? [[String: Any]] else {
            return "HomeClaw response is missing characteristic freshness metadata"
        }

        let reads = services.flatMap { service -> [[String: Any]] in
            let characteristics = service["characteristics"] as? [[String: Any]] ?? []
            return characteristics.compactMap { $0["read"] as? [String: Any] }
        }
        guard reads.count == attempted else {
            return "HomeClaw characteristic freshness count is inconsistent"
        }

        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for read in reads {
            guard read["succeeded"] as? Bool == true,
                  let observedAt = read["observed_at"] as? String,
                  timestampFormatter.date(from: observedAt) != nil
            else {
                return "HomeClaw characteristic freshness attestation is invalid"
            }
        }
        return nil
    }

    func run() throws {
        if let err = validateInput(accessory, label: "accessory") { throw ValidationError(err) }
        var args: [String: String] = ["id": accessory]
        if noRefresh { args["refresh"] = "false" }
        let response = try SocketClient.send(command: "get_accessory", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        guard let detail = response.data?.value as? [String: Any] else {
            throw ValidationError("HomeClaw returned an invalid accessory response")
        }
        if let contractError = Self.refreshContractError(
            noRefresh: noRefresh,
            detail: detail
        ) {
            throw ValidationError(contractError)
        }

        if shouldOutputJSON(json) {
            printJSON(detail)
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
        if noRefresh {
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
