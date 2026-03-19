import ArgumentParser
import Foundation

struct RemoveRoom: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove-room",
        abstract: "Remove a room from a HomeKit home"
    )

    @Argument(help: "Room name or UUID")
    var room: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview changes without applying")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: Any] = ["id": room, "dry_run": dryRun]
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "remove_room", args: args)
        guard response.success else { throw ValidationError(response.error ?? "Unknown error") }

        if shouldOutputJSON(json) { printJSON(response.data?.value); return }

        guard let result = response.data?.value as? [String: Any] else { print("Done."); return }
        let isDryRun = result["dry_run"] as? Bool ?? false
        let roomName = result["name"] as? String ?? "?"
        let count = result["accessory_count"] as? Int ?? 0

        if isDryRun { print("DRY RUN — would remove room '\(roomName)' (\(count) accessories)") }
        else { print("Removed room '\(roomName)' (\(count) accessories moved to default room)") }
    }
}
