import ArgumentParser
import Foundation

struct DeleteScene: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-scene",
        abstract: "Delete a HomeKit scene by name"
    )

    @Argument(help: "Scene name to delete")
    var name: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Validate without deleting")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        if let err = validateInput(name, label: "name") { throw ValidationError(err) }

        var args: [String: Any] = ["name": name]
        if let home { args["home"] = home }
        if dryRun { args["dry_run"] = true }

        let response = try SocketClient.sendAny(command: "delete_scene", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }

        if let data = response.data?.value as? [String: Any] {
            if data["dry_run"] as? Bool == true {
                let sceneName = data["name"] as? String ?? name
                let homeName = data["home"] as? String ?? "?"
                let actions = data["action_count"] as? Int ?? 0
                print("Dry run: would delete scene '\(sceneName)' from \(homeName) (\(actions) action(s))")
            } else if let sceneName = data["name"] as? String,
                      let homeName = data["home"] as? String
            {
                print("Deleted scene '\(sceneName)' from \(homeName)")
            } else {
                print("Scene deleted.")
            }
        } else {
            print("Scene deleted.")
        }
    }
}
