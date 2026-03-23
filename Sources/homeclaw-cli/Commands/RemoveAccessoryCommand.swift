import ArgumentParser
import Foundation

struct RemoveAccessory: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove-accessory",
        abstract: "Remove an accessory from a HomeKit home"
    )

    @Argument(help: "Accessory name or UUID")
    var accessory: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview changes without applying")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: Any] = ["id": accessory, "dry_run": dryRun]
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "remove_accessory", args: args)

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
        let name = result["name"] as? String ?? "?"
        let room = result["room"] as? String ?? "?"

        if isDryRun {
            print("DRY RUN — would remove '\(name)' from \(room)")
        } else {
            print("Removed '\(name)' from \(room)")
        }
    }
}
