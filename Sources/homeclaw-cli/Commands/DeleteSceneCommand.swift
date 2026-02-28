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

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: Any] = ["name": name]
        if let home { args["home"] = home }

        let response = try SocketClient.sendAny(command: "delete_scene", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if json {
            printJSON(response.data?.value)
            return
        }

        if let data = response.data?.value as? [String: Any],
           let sceneName = data["name"] as? String,
           let homeName = data["home"] as? String
        {
            print("Deleted scene '\(sceneName)' from \(homeName)")
        } else {
            print("Scene deleted.")
        }
    }
}
