import ArgumentParser
import Foundation

struct Triggers: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "triggers",
        abstract: "Manage webhook triggers",
        subcommands: [
            ListTriggers.self,
            AddTrigger.self,
            RemoveTrigger.self,
            UpdateTrigger.self,
        ],
        defaultSubcommand: ListTriggers.self
    )
}

// MARK: - List

struct ListTriggers: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all webhook triggers"
    )

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        let response = try SocketClient.send(command: "list_triggers")
        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }

        guard let data = response.data?.value as? [String: Any],
              let triggers = data["triggers"] as? [[String: Any]]
        else {
            print("No triggers configured.")
            return
        }

        if triggers.isEmpty {
            print("No triggers configured.")
            return
        }

        for trigger in triggers {
            let id = trigger["id"] as? String ?? "?"
            let label = trigger["label"] as? String ?? "Untitled"
            let enabled = trigger["enabled"] as? Bool ?? false
            let wakeMode = trigger["wake_mode"] as? String ?? "next-heartbeat"
            let action = trigger["action"] as? String ?? "wake"

            let status = enabled ? "enabled" : "disabled"
            var details: [String] = []

            if let accID = trigger["accessory_id"] as? String {
                details.append("accessory: \(accID)")
            }
            if let sceneID = trigger["scene_id"] as? String {
                details.append("scene: \(sceneID)")
            } else if let sceneName = trigger["scene_name"] as? String {
                details.append("scene: \(sceneName)")
            }
            if let char = trigger["characteristic"] as? String {
                details.append("characteristic: \(char)")
            }
            if let val = trigger["value"] as? String {
                details.append("value: \(val)")
            }

            let delivery = action == "agent" ? "agent" : wakeMode
            let detailStr = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
            print("  [\(status)] \(label)\(detailStr) [\(delivery)] [\(id)]")
        }
    }
}

// MARK: - Add

struct AddTrigger: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a new webhook trigger"
    )

    @Option(name: .long, help: "Trigger label (required)")
    var label: String

    @Option(name: .long, help: "Accessory UUID to match")
    var accessoryId: String?

    @Option(name: .long, help: "Scene name to match")
    var sceneName: String?

    @Option(name: .long, help: "Scene UUID to match")
    var sceneId: String?

    @Option(name: .long, help: "Characteristic name to match (e.g. contact_state, motion_detected)")
    var characteristic: String?

    @Option(name: .long, help: "Characteristic value to match (e.g. open, true)")
    var value: String?

    @Option(name: .long, help: "Custom webhook message")
    var message: String?

    @Option(name: .long, help: "Routing action: wake (default) or agent")
    var action: String?

    @Option(name: .long, help: "Wake mode: next-heartbeat (default) or now")
    var wakeMode: String?

    @Option(name: .long, help: "Agent prompt text")
    var agentPrompt: String?

    @Option(name: .long, help: "Agent ID to route to")
    var agentId: String?

    @Option(name: .long, help: "Agent display name")
    var agentName: String?

    @Flag(name: .long, help: "Deliver agent response to messaging channel")
    var agentDeliver = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        if let err = validateInput(label, label: "label") { throw ValidationError(err) }
        if let v = accessoryId, let err = validateInput(v, label: "accessory-id") { throw ValidationError(err) }
        if let v = sceneName, let err = validateInput(v, label: "scene-name") { throw ValidationError(err) }
        if let v = characteristic, let err = validateInput(v, label: "characteristic") { throw ValidationError(err) }

        var args: [String: String] = ["label": label]
        if let v = accessoryId { args["accessory_id"] = v }
        if let v = sceneName { args["scene_name"] = v }
        if let v = sceneId { args["scene_id"] = v }
        if let v = characteristic { args["characteristic"] = v }
        if let v = value { args["value"] = v }
        if let v = message { args["message"] = v }
        if let v = action { args["action"] = v }
        if let v = wakeMode { args["wake_mode"] = v }
        if let v = agentPrompt { args["agent_prompt"] = v }
        if let v = agentId { args["agent_id"] = v }
        if let v = agentName { args["agent_name"] = v }
        if agentDeliver { args["agent_deliver"] = "true" }

        let response = try SocketClient.send(command: "add_trigger", args: args)
        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }

        if let data = response.data?.value as? [String: Any],
           let id = data["id"] as? String
        {
            print("Trigger added: \(label) [\(id)]")
        } else {
            print("Trigger added.")
        }
    }
}

// MARK: - Remove

struct RemoveTrigger: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a webhook trigger by ID"
    )

    @Argument(help: "Trigger UUID to remove")
    var id: String

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        if let err = validateInput(id, label: "id") { throw ValidationError(err) }
        let response = try SocketClient.send(command: "remove_trigger", args: ["id": id])
        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }

        print("Trigger removed.")
    }
}

// MARK: - Update

struct UpdateTrigger: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an existing webhook trigger"
    )

    @Argument(help: "Trigger UUID to update")
    var id: String

    @Option(name: .long, help: "New label")
    var label: String?

    @Option(name: .long, help: "Enable or disable (true/false)")
    var enabled: String?

    @Option(name: .long, help: "Accessory UUID (empty string to clear)")
    var accessoryId: String?

    @Option(name: .long, help: "Scene name (empty string to clear)")
    var sceneName: String?

    @Option(name: .long, help: "Scene UUID (empty string to clear)")
    var sceneId: String?

    @Option(name: .long, help: "Characteristic name (empty string to clear)")
    var characteristic: String?

    @Option(name: .long, help: "Characteristic value (empty string to clear)")
    var value: String?

    @Option(name: .long, help: "Custom webhook message (empty string to clear)")
    var message: String?

    @Option(name: .long, help: "Routing action: wake or agent (empty to clear)")
    var action: String?

    @Option(name: .long, help: "Wake mode: next-heartbeat or now (empty to clear)")
    var wakeMode: String?

    @Option(name: .long, help: "Agent prompt (empty to clear)")
    var agentPrompt: String?

    @Option(name: .long, help: "Agent ID (empty to clear)")
    var agentId: String?

    @Option(name: .long, help: "Agent name (empty to clear)")
    var agentName: String?

    @Option(name: .long, help: "Agent deliver: true/false")
    var agentDeliver: String?

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        if let err = validateInput(id, label: "id") { throw ValidationError(err) }
        if let v = label, let err = validateInput(v, label: "label") { throw ValidationError(err) }

        var args: [String: String] = ["id": id]
        if let v = label { args["label"] = v }
        if let v = enabled {
            guard v == "true" || v == "false" else {
                throw ValidationError("--enabled must be 'true' or 'false'")
            }
            args["enabled"] = v
        }
        if let v = accessoryId { args["accessory_id"] = v }
        if let v = sceneName { args["scene_name"] = v }
        if let v = sceneId { args["scene_id"] = v }
        if let v = characteristic { args["characteristic"] = v }
        if let v = value { args["value"] = v }
        if let v = message { args["message"] = v }
        if let v = action { args["action"] = v }
        if let v = wakeMode { args["wake_mode"] = v }
        if let v = agentPrompt { args["agent_prompt"] = v }
        if let v = agentId { args["agent_id"] = v }
        if let v = agentName { args["agent_name"] = v }
        if let v = agentDeliver { args["agent_deliver"] = v }

        let response = try SocketClient.send(command: "update_trigger", args: args)
        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }

        print("Trigger updated.")
    }
}
