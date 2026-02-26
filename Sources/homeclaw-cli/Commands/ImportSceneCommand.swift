import ArgumentParser
import Foundation

struct ImportSceneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-scene",
        abstract: "Import a scene from a scenes_export.json file"
    )

    @Option(name: .long, help: "Path to scenes_export.json")
    var file: String

    @Option(name: .long, help: "Scene name to import (imports all if omitted)")
    var scene: String?

    @Option(name: .long, help: "Home name (required if multiple homes)")
    var home: String?

    @Flag(name: .long, help: "Preview what would happen without making changes")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON response")
    var json = false

    func run() throws {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        guard let export = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let homes = export["homes"] as? [String: Any]
        else {
            throw ValidationError("Invalid scenes_export.json format")
        }

        var scenesToImport: [(homeName: String, scene: [String: Any])] = []

        for (homeName, scenesAny) in homes {
            if let homeFilter = home,
               homeName.caseInsensitiveCompare(homeFilter) != .orderedSame {
                continue
            }
            guard let scenes = scenesAny as? [[String: Any]] else { continue }
            for sceneData in scenes {
                guard let sceneName = sceneData["name"] as? String else { continue }
                if let sceneFilter = scene,
                   sceneName.caseInsensitiveCompare(sceneFilter) != .orderedSame {
                    continue
                }
                scenesToImport.append((homeName: homeName, scene: sceneData))
            }
        }

        guard !scenesToImport.isEmpty else {
            if let sceneName = scene {
                print("Scene '\(sceneName)' not found in export file.")
            } else {
                print("No scenes found in export file.")
            }
            throw ExitCode.failure
        }

        for (homeName, sceneData) in scenesToImport {
            guard let sceneName = sceneData["name"] as? String,
                  let actions = sceneData["actions"] as? [[String: Any]]
            else { continue }

            let validActions = actions.filter { action in
                guard let _ = action["accessory_name"] as? String,
                      let _ = action["room"] as? String,
                      let _ = action["property"] as? String,
                      let val = action["value"] as? String
                else { return false }
                return val != "None"
            }

            if validActions.isEmpty {
                print("⚠  \(sceneName): no valid actions to import, skipping")
                continue
            }

            let prefix = dryRun ? "[DRY RUN] " : ""
            print("\(prefix)Importing '\(sceneName)' into '\(homeName)' (\(validActions.count) actions)...")

            let actionDicts: [[String: Any]] = validActions.map { action in
                [
                    "accessory_name": action["accessory_name"] as Any,
                    "room": action["room"] as Any,
                    "property": action["property"] as Any,
                    "value": action["value"] as Any,
                ]
            }

            let args: [String: Any] = [
                "name": sceneName,
                "home": homeName,
                "actions": actionDicts,
                "dry_run": dryRun,
            ]

            let response = try SocketClient.sendAny(command: "import_scene", args: args)

            if json {
                printJSON(response.data?.value)
            } else if response.success, let data = response.data?.value as? [String: Any] {
                let planned = data["actions_planned"] as? Int
                    ?? data["actions_added"] as? Int ?? 0
                let skipped = data["actions_skipped"] as? Int ?? 0
                let errors = data["action_errors"] as? Int ?? 0

                if dryRun {
                    print("  ✓ Would create \(planned) action(s), skip \(skipped)")
                } else {
                    print("  ✓ Created \(planned) action(s), skipped \(skipped), errors \(errors)")
                }

                if let warnings = data["warnings"] as? [[String: String]] {
                    for w in warnings {
                        print("  ⚠  \(w["detail"] ?? "unknown")")
                    }
                }
                if let errs = data["errors"] as? [[String: String]] {
                    for e in errs {
                        print("  ✗  \(e["accessory"] ?? "?"): \(e["error"] ?? "unknown")")
                    }
                }
            } else {
                print("  ✗  \(response.error ?? "Unknown error")")
            }
        }
    }
}

struct DeleteSceneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-scene",
        abstract: "Delete a scene by name"
    )

    @Argument(help: "Scene name to delete")
    var name: String

    @Option(name: .long, help: "Home name (if multiple homes)")
    var home: String?

    @Flag(name: .long, help: "Output raw JSON response")
    var json = false

    func run() throws {
        var args: [String: String] = ["name": name]
        if let home { args["home"] = home }

        let response = try SocketClient.send(command: "delete_scene", args: args)

        if json {
            printJSON(response.data?.value)
        } else if response.success {
            print("✓ Deleted scene '\(name)'")
        } else {
            print("✗ \(response.error ?? "Unknown error")")
        }
    }
}
