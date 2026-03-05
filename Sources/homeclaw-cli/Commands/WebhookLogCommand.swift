import ArgumentParser
import Foundation

struct WebhookLog: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show webhook delivery log",
        subcommands: [List.self, Stats.self, Purge.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show recent webhook events")

        @Flag(name: .long, help: "Output raw JSON")
        var json = false

        @Option(name: .long, help: "Max entries to return (default: 50)")
        var limit: Int = 50

        @Option(name: .long, help: "Filter by outcome: delivered, failed, dropped, skipped")
        var outcome: String?

        @Option(name: .long, help: "Show entries since ISO 8601 timestamp or duration (e.g. 1h, 30m, 2d)")
        var since: String?

        func run() throws {
            var args: [String: String] = ["limit": "\(limit)"]
            if let outcome { args["outcome"] = outcome }
            if let since { args["since"] = try parseSinceValue(since) }

            let response = try SocketClient.send(command: "webhook_log", args: args)
            guard response.success else {
                throw ValidationError(response.error ?? "Unknown error")
            }

            if shouldOutputJSON(json) {
                printJSON(response.data?.value)
                return
            }

            guard let data = response.data?.value as? [String: Any],
                  let entries = data["entries"] as? [[String: Any]]
            else {
                print("No webhook log entries found.")
                return
            }

            if entries.isEmpty {
                print("No webhook log entries found.")
                return
            }

            for entry in entries {
                let timestamp = entry["timestamp"] as? String ?? ""
                let display = formatEntry(entry)
                print("  \(formatTimestamp(timestamp))  \(display)")
            }

            print("\n\(entries.count) entry(ies)")
        }

        private func formatEntry(_ entry: [String: Any]) -> String {
            let outcome = entry["outcome"] as? String ?? "unknown"
            let label = entry["trigger_label"] as? String
            let accessory = entry["accessory"] as? String
            let characteristic = entry["characteristic"] as? String
            let endpoint = entry["endpoint"] as? String
            let httpStatus = entry["http_status"] as? Int
            let error = entry["error"] as? String
            let reason = entry["reason"] as? String

            let icon: String
            switch outcome {
            case "delivered": icon = "OK"
            case "failed": icon = "FAIL"
            case "dropped": icon = "DROP"
            case "skipped": icon = "SKIP"
            default: icon = outcome.uppercased()
            }

            var parts: [String] = ["[\(icon)]"]

            if let label { parts.append(label) }
            if let accessory {
                let charSuffix = characteristic.map { " (\($0))" } ?? ""
                parts.append(accessory + charSuffix)
            }
            if let endpoint { parts.append("→ \(endpoint)") }
            if let httpStatus { parts.append("HTTP \(httpStatus)") }
            if let error { parts.append("error: \(error)") }
            if let reason { parts.append("reason: \(reason)") }

            return parts.joined(separator: "  ")
        }

        private func formatTimestamp(_ iso: String) -> String {
            let formatter = ISO8601DateFormatter()
            guard let date = formatter.date(from: iso) else { return iso }
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss"
            return df.string(from: date)
        }
    }

    struct Stats: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show webhook log file stats")

        @Flag(name: .long, help: "Output raw JSON")
        var json = false

        func run() throws {
            let response = try SocketClient.send(command: "webhook_log_stats")
            guard response.success else {
                throw ValidationError(response.error ?? "Unknown error")
            }

            if shouldOutputJSON(json) {
                printJSON(response.data?.value)
                return
            }

            guard let data = response.data?.value as? [String: Any] else {
                print("No stats available.")
                return
            }

            let fileCount = data["file_count"] as? Int ?? 0
            let sizeMB = data["total_size_mb"] as? String ?? "0.0"
            let path = data["path"] as? String ?? "?"

            print("Webhook log:")
            print("  Files: \(fileCount)")
            print("  Size:  \(sizeMB) MB")
            print("  Path:  \(path)")
        }
    }

    struct Purge: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete all webhook log files")

        func run() throws {
            let response = try SocketClient.send(command: "purge_webhook_log")
            guard response.success else {
                throw ValidationError(response.error ?? "Unknown error")
            }
            print("Webhook log purged.")
        }
    }
}
