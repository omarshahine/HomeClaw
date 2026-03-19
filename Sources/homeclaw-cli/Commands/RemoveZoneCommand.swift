import ArgumentParser
import Foundation

struct RemoveZone: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove-zone",
        abstract: "Remove a zone from a HomeKit home"
    )

    @Argument(help: "Zone name or UUID")
    var zone: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview changes without applying")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: Any] = ["id": zone, "dry_run": dryRun]
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "remove_zone", args: args)
        guard response.success else { throw ValidationError(response.error ?? "Unknown error") }

        if shouldOutputJSON(json) { printJSON(response.data?.value); return }

        guard let result = response.data?.value as? [String: Any] else { print("Done."); return }
        let isDryRun = result["dry_run"] as? Bool ?? false
        let zoneName = result["name"] as? String ?? "?"
        let roomCount = result["room_count"] as? Int ?? 0

        if isDryRun { print("DRY RUN — would remove zone '\(zoneName)' (\(roomCount) rooms)") }
        else { print("Removed zone '\(zoneName)' (\(roomCount) rooms unzoned)") }
    }
}
