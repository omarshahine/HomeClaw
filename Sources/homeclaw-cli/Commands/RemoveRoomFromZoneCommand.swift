import ArgumentParser
import Foundation

struct RemoveRoomFromZone: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove-room-from-zone",
        abstract: "Remove a room from a zone"
    )

    @Argument(help: "Room name or UUID")
    var room: String

    @Argument(help: "Zone name or UUID")
    var zone: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview changes without applying")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: Any] = ["room": room, "zone": zone, "dry_run": dryRun]
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "remove_room_from_zone", args: args)
        guard response.success else { throw ValidationError(response.error ?? "Unknown error") }

        if shouldOutputJSON(json) { printJSON(response.data?.value); return }

        guard let result = response.data?.value as? [String: Any] else { print("Done."); return }
        let isDryRun = result["dry_run"] as? Bool ?? false
        let roomName = result["room"] as? String ?? "?"
        let zoneName = result["zone"] as? String ?? "?"

        if isDryRun { print("DRY RUN — would remove '\(roomName)' from zone '\(zoneName)'") }
        else { print("Removed '\(roomName)' from zone '\(zoneName)'") }
    }
}
