import ArgumentParser
import Foundation

struct AssignRoomsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assign-rooms",
        abstract: "Assign accessories to rooms from an accessory_rooms.json export"
    )

    @Option(name: .long, help: "Path to accessory_rooms.json")
    var file: String

    @Option(name: .long, help: "Home name (required if multiple homes)")
    var home: String?

    @Flag(name: .long, help: "Preview what would happen without making changes")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON response")
    var json = false

    func run() throws {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        guard let export = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let homes = export["homes"] as? [String: Any]
        else {
            throw ValidationError("Invalid accessory_rooms.json format")
        }

        for (homeName, accessoriesAny) in homes {
            if let homeFilter = home,
               homeName.caseInsensitiveCompare(homeFilter) != .orderedSame {
                continue
            }
            guard let accessories = accessoriesAny as? [[String: Any]] else { continue }

            let assignments: [[String: Any]] = accessories.compactMap { acc in
                guard let name = acc["name"] as? String,
                      let room = acc["room"] as? String
                else { return nil }
                return [
                    "accessory_name": name,
                    "room": room,
                    "manufacturer": acc["manufacturer"] as Any,
                    "model": acc["model"] as Any,
                ]
            }

            if assignments.isEmpty {
                print("⚠  \(homeName): no assignments to make")
                continue
            }

            let prefix = dryRun ? "[DRY RUN] " : ""
            print("\(prefix)Assigning \(assignments.count) accessories to rooms in '\(homeName)'...")

            let args: [String: Any] = [
                "home": homeName,
                "assignments": assignments,
                "dry_run": dryRun,
            ]

            let response = try SocketClient.sendAny(command: "assign_rooms", args: args)

            if json {
                printJSON(response.data?.value)
            } else if response.success, let data = response.data?.value as? [String: Any] {
                let assigned = data["assigned"] as? Int ?? 0
                let skipped = data["skipped"] as? Int ?? 0
                let already = data["already_correct"] as? Int ?? 0
                let notFound = data["not_found"] as? Int ?? 0

                if dryRun {
                    print("  ✓ Would assign \(assigned), already correct \(already), not found \(notFound)")
                } else {
                    print("  ✓ Assigned \(assigned), already correct \(already), skipped \(skipped), not found \(notFound)")
                }

                if let warnings = data["warnings"] as? [[String: String]] {
                    for w in warnings {
                        print("  ⚠  \(w["detail"] ?? "unknown")")
                    }
                }
                if let errors = data["errors"] as? [[String: String]] {
                    for e in errors {
                        print("  ✗  \(e["accessory"] ?? "?"): \(e["error"] ?? "unknown")")
                    }
                }
            } else {
                print("  ✗  \(response.error ?? "Unknown error")")
            }
        }
    }
}
