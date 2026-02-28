import ArgumentParser
import Foundation

struct Events: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show recent HomeKit events"
    )

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    @Option(name: .long, help: "Max events to return (default: 50)")
    var limit: Int = 50

    @Option(name: .long, help: "Filter by event type: characteristic_change, homes_updated, scene_triggered, accessory_controlled")
    var type: String?

    @Option(name: .long, help: "Show events since this ISO 8601 timestamp or duration (e.g. 1h, 30m, 2d)")
    var since: String?

    func run() throws {
        var args: [String: String] = ["limit": "\(limit)"]
        if let type { args["type"] = type }
        if let since { args["since"] = parseSince(since) }

        let response = try SocketClient.send(command: "events", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if json {
            printJSON(response.data?.value)
            return
        }

        guard let data = response.data?.value as? [String: Any],
              let events = data["events"] as? [[String: Any]]
        else {
            print("No events found.")
            return
        }

        if events.isEmpty {
            print("No events found.")
            return
        }

        for event in events {
            let timestamp = event["timestamp"] as? String ?? ""
            let type = event["type"] as? String ?? "unknown"
            let display = formatEvent(type: type, event: event)
            print("  \(formatTimestamp(timestamp))  \(display)")
        }

        print("\n\(events.count) event(s)")
    }

    private func parseSince(_ value: String) -> String {
        // Try ISO 8601 first
        if ISO8601DateFormatter().date(from: value) != nil {
            return value
        }

        // Try duration shorthand: 1h, 30m, 2d
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        var seconds: TimeInterval = 0
        if trimmed.hasSuffix("h"), let n = Double(trimmed.dropLast()) {
            seconds = n * 3600
        } else if trimmed.hasSuffix("m"), let n = Double(trimmed.dropLast()) {
            seconds = n * 60
        } else if trimmed.hasSuffix("d"), let n = Double(trimmed.dropLast()) {
            seconds = n * 86400
        }

        if seconds > 0 {
            return ISO8601DateFormatter().string(from: Date().addingTimeInterval(-seconds))
        }

        return value
    }

    private func formatTimestamp(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: date)
    }

    private func formatEvent(type: String, event: [String: Any]) -> String {
        switch type {
        case "characteristic_change":
            let accessory = event["accessory"] as? [String: Any]
            let name = accessory?["name"] as? String ?? "?"
            let room = accessory?["room"] as? String
            let char = event["characteristic"] as? String ?? ""
            let value = event["value"] as? String ?? ""
            let prev = event["previous_value"] as? String
            let location = room.map { " (\($0))" } ?? ""
            let delta = prev.map { "\($0) → \(value)" } ?? value
            return "\(name)\(location): \(char) = \(delta)"

        case "scene_triggered":
            let scene = event["scene"] as? [String: Any]
            let name = scene?["name"] as? String ?? "?"
            return "Scene triggered: \(name)"

        case "accessory_controlled":
            let accessory = event["accessory"] as? [String: Any]
            let name = accessory?["name"] as? String ?? "?"
            let char = event["characteristic"] as? String ?? ""
            let value = event["value"] as? String ?? ""
            return "Control: \(name) \(char) → \(value)"

        case "homes_updated":
            let homes = event["homes"] as? Int ?? 0
            let accessories = event["accessories"] as? Int ?? 0
            return "Homes updated: \(homes) home(s), \(accessories) accessory(ies)"

        default:
            return type
        }
    }
}
