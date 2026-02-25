import ArgumentParser
import Foundation

struct Scenes: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List all HomeKit scenes"
    )

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        let response = try SocketClient.send(command: "list_scenes")

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if json {
            printJSON(response.data?.value)
            return
        }

        guard let scenes = response.data?.value as? [[String: Any]] else {
            print("No scenes found.")
            return
        }

        if scenes.isEmpty {
            print("No scenes found.")
            return
        }

        for scene in scenes {
            let name = scene["name"] as? String ?? "Unknown"
            let type = scene["type"] as? String ?? "unknown"
            let actionCount = scene["action_count"] as? Int ?? 0
            print("  \(name) [\(type)] — \(actionCount) action(s)")
        }
    }
}

struct Trigger: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Trigger a HomeKit scene"
    )

    @Argument(help: "Scene name or UUID")
    var scene: String

    func run() throws {
        let response = try SocketClient.send(command: "trigger_scene", args: ["id": scene])

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if let data = response.data?.value as? [String: Any],
           let name = data["name"] as? String
        {
            print("Triggered scene: \(name)")
        } else {
            print("Scene triggered.")
        }
    }
}
