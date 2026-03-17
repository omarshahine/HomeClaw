import ArgumentParser
import Foundation

struct GetScene: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get-scene",
        abstract: "Show details of a HomeKit scene including all actions"
    )

    @Argument(help: "Scene name or UUID")
    var scene: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        if let err = validateInput(scene, label: "scene") { throw ValidationError(err) }

        var args: [String: String] = ["id": scene]
        if let home { args["home_id"] = home }

        let response = try SocketClient.send(command: "get_scene", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }

        guard let result = response.data?.value as? [String: Any] else {
            print("No scene data returned.")
            return
        }

        let name = result["name"] as? String ?? "Unknown"
        let type = result["type"] as? String ?? "unknown"
        let homeName = result["home_name"] as? String ?? "?"
        let actionCount = result["action_count"] as? Int ?? 0

        print("\(name) [\(type)]")
        print("Home: \(homeName)")
        print("Actions: \(actionCount)\n")

        if let actions = result["actions"] as? [[String: String]] {
            for action in actions {
                let accessory = action["accessory"] ?? "?"
                let room = action["room"] ?? "?"
                let characteristic = action["characteristic"] ?? "?"
                let value = action["value"] ?? "?"
                print("  \(accessory) (\(room)): \(characteristic) → \(value)")
            }
        }
    }
}
