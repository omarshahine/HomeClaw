import ArgumentParser
import Foundation

struct UpdateScene: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update-scene",
        abstract:
            "Replace the actions on an existing scene in-place (preserves UUID; automations remain wired)"
    )

    @Argument(help: "Path to JSON file with scene definition")
    var file: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview changes without modifying the scene")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        let url = URL(fileURLWithPath: file)
        let data = try Data(contentsOf: url)
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actions = parsed["actions"] as? [[String: String]]
        else {
            throw ValidationError(
                "JSON file must contain 'actions' array of "
                    + "{\"accessory\": \"...\", \"property\": \"...\", \"value\": \"...\"} objects, "
                    + "plus either 'id' (preferred) or 'name' to identify the scene"
            )
        }
        let id = parsed["id"] as? String
        let name = parsed["name"] as? String
        guard id != nil || name != nil else {
            throw ValidationError("JSON file must contain 'id' or 'name'")
        }

        var args: [String: Any] = [
            "actions": actions,
            "dry_run": dryRun,
        ]
        if let id { args["id"] = id }
        if let name { args["name"] = name }
        if let home { args["home"] = home }

        let response = try SocketClient.sendAny(command: "update_scene", args: args)

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
        let sceneName = result["name"] as? String ?? name ?? id ?? "?"
        let sceneID = result["id"] as? String ?? id ?? "?"
        let homeName = result["home"] as? String ?? "?"
        let warnings = result["warnings"] as? [String] ?? []

        if isDryRun {
            let existingCount = result["existing_action_count"] as? Int ?? 0
            let resolvedCount = result["resolved_actions"] as? Int ?? 0
            print("DRY RUN — no changes made\n")
            print("Scene: \(sceneName) [\(sceneID)]")
            print("Home: \(homeName)")
            print("Existing actions: \(existingCount) (will be removed)")
            print("New actions:      \(resolvedCount) (will be added)")

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
            let removed = result["removed_action_count"] as? Int ?? 0
            let added = result["added_action_count"] as? Int ?? 0
            print(
                "Updated scene '\(sceneName)' in \(homeName): removed \(removed), added \(added) action(s)"
            )
            print("UUID preserved: \(sceneID)")
        }

        if !warnings.isEmpty {
            print("\nWarnings:")
            for warning in warnings {
                print("  ⚠ \(warning)")
            }
        }
    }
}
