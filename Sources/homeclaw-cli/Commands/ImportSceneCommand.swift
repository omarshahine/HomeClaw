import ArgumentParser
import Foundation

struct ImportScene: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-scene",
        abstract: "Import a HomeKit scene from a JSON file"
    )

    @Argument(help: "Path to JSON file with scene definition")
    var file: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview changes without creating the scene")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        // Read and parse the JSON file
        let url = URL(fileURLWithPath: file)
        let data = try Data(contentsOf: url)
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = parsed["name"] as? String,
              let actions = parsed["actions"] as? [[String: String]]
        else {
            throw ValidationError(
                "JSON file must contain 'name' (string) and 'actions' array of "
                    + "{\"accessory\": \"...\", \"property\": \"...\", \"value\": \"...\"} objects"
            )
        }

        var args: [String: Any] = [
            "name": name,
            "actions": actions,
            "dry_run": dryRun,
        ]
        if let home { args["home"] = home }

        let response = try SocketClient.sendAny(command: "import_scene", args: args)

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
        let sceneName = result["name"] as? String ?? name
        let homeName = result["home"] as? String ?? "?"
        let warnings = result["warnings"] as? [String] ?? []

        if isDryRun {
            let resolvedCount = result["resolved_actions"] as? Int ?? 0
            print("DRY RUN — no scene created\n")
            print("Scene: \(sceneName)")
            print("Home: \(homeName)")
            print("Resolved actions: \(resolvedCount)")

            if let actions = result["actions"] as? [[String: String]] {
                for action in actions {
                    let accessory = action["accessory"] ?? "?"
                    let room = action["room"] ?? "?"
                    let characteristic = action["characteristic"] ?? "?"
                    let value = action["value"] ?? "?"
                    print("  \(accessory) (\(room)): \(characteristic) = \(value)")
                }
            }
        } else {
            let actionCount = result["action_count"] as? Int ?? 0
            print("Created scene '\(sceneName)' in \(homeName) with \(actionCount) action(s)")
        }

        if !warnings.isEmpty {
            print("\nWarnings:")
            for warning in warnings {
                print("  ⚠ \(warning)")
            }
        }
    }
}
