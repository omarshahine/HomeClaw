import ArgumentParser
import Foundation

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "View or update HomeClaw configuration"
    )

    @Option(name: .long, help: "Set active home by name or UUID")
    var defaultHome: String?

    @Flag(name: .long, help: "Reset default home to primary home")
    var clear = false

    @Option(name: .long, help: "Set filter mode: 'all' or 'allowlist'")
    var filterMode: String?

    @Option(name: .long, help: "Set allowed accessory IDs (comma-separated UUIDs)")
    var allowAccessories: String?

    @Flag(name: .long, help: "Show all accessories with their allowed status")
    var listDevices = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        // List devices mode
        if listDevices {
            try showDeviceList()
            return
        }

        if clear {
            // Find the primary home and set it as default
            let homesResponse = try SocketClient.send(command: "list_homes")
            var primaryID: String?
            if let homesList = homesResponse.data?.value as? [[String: Any]] {
                if let primary = homesList.first(where: { $0["is_primary"] as? Bool == true }) {
                    primaryID = primary["id"] as? String
                } else if let first = homesList.first {
                    primaryID = first["id"] as? String
                }
            }
            guard let homeID = primaryID else {
                throw ValidationError("No homes available")
            }
            let response = try SocketClient.send(
                command: "set_config",
                args: ["default_home_id": homeID]
            )
            guard response.success else {
                throw ValidationError(response.error ?? "Unknown error")
            }
            if json {
                printJSON(response.data?.value)
            } else {
                print("Active home reset to primary home.")
            }
            return
        }

        // Apply settings if any options provided
        if defaultHome != nil || filterMode != nil || allowAccessories != nil {
            var args: [String: Any] = [:]

            if let home = defaultHome {
                args["default_home_id"] = home
            }
            if let mode = filterMode {
                guard mode == "all" || mode == "allowlist" else {
                    throw ValidationError("Filter mode must be 'all' or 'allowlist'")
                }
                args["accessory_filter_mode"] = mode
            }
            if let ids = allowAccessories {
                args["allowed_accessory_ids"] = ids.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            }

            let response = try SocketClient.sendAny(command: "set_config", args: args)
            guard response.success else {
                throw ValidationError(response.error ?? "Unknown error")
            }
            if json {
                printJSON(response.data?.value)
            } else {
                print("Configuration updated.")
                if let data = response.data?.value as? [String: Any] {
                    printConfigSummary(data)
                }
            }
            return
        }

        // Show current config
        let response = try SocketClient.send(command: "get_config")
        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if json {
            printJSON(response.data?.value)
            return
        }

        guard let data = response.data?.value as? [String: Any] else {
            print("Could not parse config.")
            return
        }

        let config = data["config"] as? [String: Any] ?? [:]
        let defaultID = config["default_home_id"] as? String
        let mode = config["accessory_filter_mode"] as? String ?? "all"
        let totalCount = data["total_accessories"] as? Int ?? 0
        let filteredCount = data["filtered_accessories"] as? Int ?? 0

        print("HomeClaw Configuration")
        print("  Config file:   ~/.config/homeclaw/config.json")

        // Resolve active home name from available homes
        let homes = data["available_homes"] as? [[String: Any]] ?? []
        let activeHome = homes.first(where: { ($0["is_selected"] as? Bool) == true })
        let activeName = activeHome?["name"] as? String
        if let activeName {
            print("  Active home:   \(activeName)")
        } else if let defaultID {
            print("  Active home:   \(defaultID)")
        } else {
            print("  Active home:   (primary home)")
        }
        print("  Filter mode:   \(mode)")
        print("  Accessories:   \(filteredCount) of \(totalCount) exposed")

        if !homes.isEmpty {
            print("\nAvailable homes:")
            for home in homes {
                let name = home["name"] as? String ?? "Unknown"
                let id = home["id"] as? String ?? "?"
                let accessories = home["accessory_count"] as? Int ?? 0
                let isSelected = home["is_selected"] as? Bool ?? false
                let marker = isSelected ? " *" : ""
                print("  \(name) (\(accessories) accessories) [\(id)]\(marker)")
            }
        }
    }

    private func showDeviceList() throws {
        // Get all accessories (unfiltered)
        let allResponse = try SocketClient.send(command: "list_all_accessories")
        guard allResponse.success else {
            throw ValidationError(allResponse.error ?? "Unknown error")
        }

        // Get current config for allowed IDs
        let configResponse = try SocketClient.send(command: "get_config")
        var mode = "all"
        var allowedIDs: [String] = []
        if let configData = configResponse.data?.value as? [String: Any],
           let config = configData["config"] as? [String: Any]
        {
            mode = config["accessory_filter_mode"] as? String ?? "all"
            if let ids = config["allowed_accessory_ids"] as? [String] {
                allowedIDs = ids
            }
        }

        if json {
            printJSON(allResponse.data?.value)
            return
        }

        guard let accessories = allResponse.data?.value as? [[String: Any]] else {
            print("No accessories found.")
            return
        }

        print("All Accessories (filter mode: \(mode))")
        print("")

        // Group by room
        var grouped: [String: [[String: Any]]] = [:]
        for acc in accessories {
            let room = acc["room"] as? String ?? "No Room"
            grouped[room, default: []].append(acc)
        }

        var allowedCount = 0
        for room in grouped.keys.sorted() {
            print("  \(room):")
            for acc in grouped[room]! {
                let id = acc["id"] as? String ?? "?"
                let name = acc["name"] as? String ?? "Unknown"
                let category = acc["category"] as? String ?? ""
                let isAllowed = mode == "all" || allowedIDs.isEmpty || allowedIDs.contains(id)
                let marker = isAllowed ? "\u{2611}" : "\u{2610}"
                if isAllowed { allowedCount += 1 }
                print("    \(marker) \(name)  (\(category))  [\(id)]")
            }
        }
        print("\n\(allowedCount) of \(accessories.count) accessories exposed")
    }

    private func printConfigSummary(_ config: [String: Any]) {
        let mode = config["accessory_filter_mode"] as? String ?? "all"
        print("  Filter mode: \(mode)")
        if let ids = config["allowed_accessory_ids"] as? [String] {
            print("  Allowed accessories: \(ids.count)")
        }
    }
}
