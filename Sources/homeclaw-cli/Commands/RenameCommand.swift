import ArgumentParser
import Foundation

struct Rename: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a HomeKit accessory"
    )

    @Argument(help: "Accessory name or UUID")
    var accessory: String

    @Argument(help: "New name for the accessory")
    var newName: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview changes without applying")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: Any] = [
            "id": accessory,
            "new_name": newName,
            "dry_run": dryRun,
        ]
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "rename", args: args)

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

        let oldName = result["old_name"] as? String ?? "?"
        let renamedTo = result["new_name"] as? String ?? "?"
        let isDryRun = result["dry_run"] as? Bool ?? false

        if isDryRun {
            print("DRY RUN — would rename '\(oldName)' → '\(renamedTo)'")
        } else {
            print("Renamed '\(oldName)' → '\(renamedTo)'")
        }
    }
}
