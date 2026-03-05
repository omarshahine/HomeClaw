import ArgumentParser
import Foundation

struct AssignRooms: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assign-rooms",
        abstract: "Assign accessories to rooms from a JSON file"
    )

    @Argument(help: "Path to JSON file with assignments array [{\"accessory\": \"...\", \"room\": \"...\"}]")
    var file: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview changes without applying")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        // Read and parse the JSON file
        let url = URL(fileURLWithPath: file)
        let data = try Data(contentsOf: url)
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assignments = parsed["assignments"] as? [[String: String]]
        else {
            throw ValidationError("JSON file must contain an 'assignments' array of {\"accessory\": \"...\", \"room\": \"...\"} objects")
        }

        var args: [String: Any] = [
            "assignments": assignments,
            "dry_run": dryRun,
        ]
        if let home { args["home"] = home }

        let response = try SocketClient.sendAny(command: "assign_rooms", args: args)

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

        let assigned = result["assigned"] as? Int ?? 0
        let skipped = result["skipped"] as? Int ?? 0
        let notFound = result["not_found"] as? [String] ?? []
        let isDryRun = result["dry_run"] as? Bool ?? false
        let homeName = result["home"] as? String ?? "?"

        if isDryRun { print("DRY RUN — no changes applied\n") }
        print("Home: \(homeName)")

        if let details = result["details"] as? [[String: String]] {
            for detail in details {
                let accessory = detail["accessory"] ?? "?"
                let room = detail["room"] ?? "?"
                let status = detail["status"] ?? "?"
                print("  \(accessory) → \(room) [\(status)]")
            }
        }

        print("\nAssigned: \(assigned), Skipped: \(skipped), Not found: \(notFound.count)")
        if !notFound.isEmpty {
            print("Missing accessories: \(notFound.joined(separator: ", "))")
        }
    }
}
