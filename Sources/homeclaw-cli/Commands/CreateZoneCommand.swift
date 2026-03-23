import ArgumentParser
import Foundation

struct CreateZone: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-zone",
        abstract: "Create a new zone in a HomeKit home"
    )

    @Argument(help: "Name for the new zone")
    var name: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview changes without applying")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: Any] = ["name": name, "dry_run": dryRun]
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "create_zone", args: args)

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
        let zoneName = result["name"] as? String ?? "?"

        if isDryRun {
            print("DRY RUN — would create zone '\(zoneName)'")
        } else {
            print("Created zone '\(zoneName)'")
        }
    }
}
