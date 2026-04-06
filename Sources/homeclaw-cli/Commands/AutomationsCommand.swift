import ArgumentParser
import Foundation

struct Automations: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "automations",
        abstract: "Manage HomeKit automations (event triggers)",
        subcommands: [
            ListAutomations.self,
            GetAutomation.self,
            CreateAutomation.self,
            DeleteAutomation.self,
            EnableAutomation.self,
            DisableAutomation.self,
        ],
        defaultSubcommand: ListAutomations.self
    )
}

// MARK: - List

struct ListAutomations: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all HomeKit automations"
    )

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: String] = [:]
        if let home { args["home_id"] = home }

        let response = try SocketClient.send(command: "list_automations", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }

        guard let automations = response.data?.value as? [[String: Any]], !automations.isEmpty else {
            print("No automations found.")
            return
        }

        for auto in automations {
            let name = auto["name"] as? String ?? "Unknown"
            let enabled = auto["enabled"] as? Bool ?? false
            let summary = auto["event_summary"] as? String ?? ""
            let scenes = auto["scenes"] as? [String] ?? []
            let status = enabled ? "enabled" : "disabled"
            let sceneStr = scenes.joined(separator: ", ")
            print("  [\(status)] \(name)")
            if !summary.isEmpty { print("    Event: \(summary)") }
            if !sceneStr.isEmpty { print("    Scene: \(sceneStr)") }
        }

        print("\n\(automations.count) automation(s)")
    }
}

// MARK: - Get

struct GetAutomation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show details of a HomeKit automation"
    )

    @Argument(help: "Automation name or UUID")
    var id: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: String] = ["id": id]
        if let home { args["home_id"] = home }

        let response = try SocketClient.send(command: "get_automation", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }

        guard let result = response.data?.value as? [String: Any] else {
            print("No automation data returned.")
            return
        }

        let name = result["name"] as? String ?? "Unknown"
        let enabled = result["enabled"] as? Bool ?? false
        let homeName = result["home"] as? String ?? "?"

        print("\(name) [\(enabled ? "enabled" : "disabled")]")
        print("Home: \(homeName)")

        if let events = result["events"] as? [[String: Any]] {
            print("\nEvents:")
            for event in events {
                let accessory = event["accessory"] as? String ?? "?"
                let pressType = event["press_type"] as? String ?? "?"
                let serviceIndex = event["service_index"] as? Int
                var line = "  \(accessory): \(pressType)"
                if let idx = serviceIndex { line += " (button \(idx))" }
                print(line)
            }
        }

        if let actionSets = result["action_sets"] as? [[String: Any]] {
            print("\nScenes:")
            for scene in actionSets {
                let sceneName = scene["name"] as? String ?? "?"
                let actionCount = scene["action_count"] as? Int ?? 0
                print("  \(sceneName) (\(actionCount) action(s))")
            }
        }
    }
}

// MARK: - Create

struct CreateAutomation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create an automation triggered by a characteristic change (button press, motion, contact, occupancy, etc.)"
    )

    @Option(name: .long, help: "Name for the automation")
    var name: String

    @Option(name: .long, help: "Trigger accessory name or UUID")
    var accessory: String

    @Option(name: .long, help: "Scene name or UUID to trigger (alternative to --action)")
    var scene: String?

    @Option(name: .long, parsing: .upToNextOption, help: "Inline action as 'accessory:property:value' (repeatable, alternative to --scene). Accessory names with colons are not supported; use the MCP actions array instead.")
    var action: [String] = []

    @Option(name: .long, help: "Press type: single, double, or long (default: single). For button triggers only; mutually exclusive with --characteristic.")
    var press: String = "single"

    @Option(name: .long, help: "Characteristic to trigger on (e.g., motion_detected, contact_state, occupancy_detected). Mutually exclusive with --press.")
    var characteristic: String?

    @Option(name: .long, help: "Value that triggers the automation (e.g., true, false, 1, 0). Required when --characteristic is set.")
    var triggerValue: String?

    @Option(name: .long, help: "Button index for multi-button accessories (e.g., 1 or 2). For button triggers only.")
    var serviceIndex: Int?

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview changes without creating")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        guard scene != nil || !action.isEmpty else {
            throw ValidationError("Either --scene or --action is required")
        }

        var args: [String: Any] = [
            "name": name,
            "accessory_id": accessory,
            "dry_run": dryRun,
        ]

        if let characteristic {
            // Generic characteristic trigger mode
            guard press == "single" else {
                throw ValidationError("--press and --characteristic are mutually exclusive")
            }
            guard let triggerValue else {
                throw ValidationError("--trigger-value is required when --characteristic is set")
            }
            args["characteristic"] = characteristic
            args["trigger_value"] = triggerValue
        } else {
            // Button press trigger mode
            let pressType: Int
            switch press.lowercased() {
            case "single", "0": pressType = 0
            case "double", "1": pressType = 1
            case "long", "2": pressType = 2
            default: throw ValidationError("Invalid press type '\(press)'. Use: single, double, or long")
            }
            args["press_type"] = pressType
        }

        if let scene {
            args["scene_id"] = scene
        } else {
            // Parse inline actions from "accessory:property:value" format
            var parsedActions: [[String: String]] = []
            for actionStr in action {
                let parts = actionStr.split(separator: ":", maxSplits: 2).map(String.init)
                guard parts.count == 3 else {
                    throw ValidationError("Invalid action format '\(actionStr)'. Use 'accessory:property:value'")
                }
                parsedActions.append([
                    "accessory": parts[0],
                    "property": parts[1],
                    "value": parts[2],
                ])
            }
            args["actions"] = parsedActions
        }

        if let serviceIndex { args["service_index"] = serviceIndex }
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "create_automation", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }

        guard let result = response.data?.value as? [String: Any] else {
            print("Done.")
            return
        }

        let isDryRun = result["dry_run"] as? Bool ?? false
        let autoName = result["name"] as? String ?? name
        let accessoryName = result["accessory"] as? String ?? "?"
        let triggerType = result["trigger_type"] as? String ?? "button"
        let actionCount = result["action_count"] as? Int
        let isInline = result["inline_actions"] as? Bool ?? false

        let triggerDescription: String
        if triggerType == "button" {
            let pressName = result["press_type"] as? String ?? "?"
            triggerDescription = "\(accessoryName) \(pressName)"
        } else {
            let charName = result["characteristic"] as? String ?? "?"
            let charValue = result["trigger_value"] as? String ?? "?"
            triggerDescription = "\(accessoryName) \(charName) = \(charValue)"
        }

        if isDryRun {
            print("DRY RUN — would create automation '\(autoName)'")
            print("  Trigger: \(triggerDescription)")
            if isInline, let actions = result["actions"] as? [[String: String]] {
                print("  Actions:")
                for a in actions {
                    let acc = a["accessory"] ?? "?"
                    let char = a["characteristic"] ?? "?"
                    let val = a["value"] ?? "?"
                    print("    \(acc): \(char) = \(val)")
                }
            } else if let sceneName = result["scene"] as? String {
                print("  Scene: \(sceneName)")
            }
        } else {
            if isInline {
                print("Created automation '\(autoName)' with \(actionCount ?? 0) inline action(s)")
                print("  \(triggerDescription) → \(actionCount ?? 0) action(s)")
            } else {
                let sceneName = result["scene"] as? String ?? "?"
                print("Created automation '\(autoName)'")
                print("  \(triggerDescription) → \(sceneName)")
            }
        }
    }
}

// MARK: - Delete

struct DeleteAutomation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a HomeKit automation"
    )

    @Argument(help: "Automation name or UUID")
    var id: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview without deleting")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: Any] = ["id": id, "dry_run": dryRun]
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "delete_automation", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }

        guard let result = response.data?.value as? [String: Any] else {
            print("Done.")
            return
        }

        let isDryRun = result["dry_run"] as? Bool ?? false
        let autoName = result["name"] as? String ?? "?"

        if isDryRun {
            let sceneCount = result["scene_count"] as? Int ?? 0
            print("DRY RUN — would delete automation '\(autoName)' (\(sceneCount) linked scene(s))")
        } else {
            print("Deleted automation '\(autoName)'")
        }
    }
}

// MARK: - Enable / Disable

struct EnableAutomation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable a HomeKit automation"
    )

    @Argument(help: "Automation name or UUID")
    var id: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    func run() throws {
        var args: [String: Any] = ["id": id, "enabled": true]
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "enable_automation", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if let result = response.data?.value as? [String: Any],
           let name = result["name"] as? String
        {
            print("Enabled automation '\(name)'")
        } else {
            print("Automation enabled.")
        }
    }
}

struct DisableAutomation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable a HomeKit automation"
    )

    @Argument(help: "Automation name or UUID")
    var id: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    func run() throws {
        var args: [String: Any] = ["id": id, "enabled": false]
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "enable_automation", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if let result = response.data?.value as? [String: Any],
           let name = result["name"] as? String
        {
            print("Disabled automation '\(name)'")
        } else {
            print("Automation disabled.")
        }
    }
}
