import ArgumentParser
import Foundation

struct AddRoomToZone: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-room-to-zone",
        abstract: "Add a room to a zone"
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

        let response = try SocketClient.sendAny(command: "add_room_to_zone", args: args)

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
        let roomName = result["room"] as? String ?? "?"
        let zoneName = result["zone"] as? String ?? "?"

        if isDryRun {
            print("DRY RUN — would add '\(roomName)' to zone '\(zoneName)'")
        } else {
            print("Added '\(roomName)' to zone '\(zoneName)'")
        }
    }
}
