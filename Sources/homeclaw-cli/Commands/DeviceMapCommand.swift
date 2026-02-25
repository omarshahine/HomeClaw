import ArgumentParser
import Foundation

struct DeviceMapCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-map",
        abstract: "Show LLM-optimized device map with semantic types and aliases"
    )

    @Flag(name: .long, help: "Output raw JSON (shorthand for --format json)")
    var json = false

    @Option(name: .long, help: "Output format: text (default), json, md, agent")
    var format: OutputFormat?

    @Option(name: .shortAndLong, help: "Write output to file instead of stdout")
    var output: String?

    enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
        case text
        case json
        case md
        /// Flat JSON optimized for LLM agents — display_name, id, room, type, controls, state.
        /// Designed for device disambiguation (e.g. resolving "Overhead" to the right room/UUID).
        case agent
    }

    func run() throws {
        let response = try SocketClient.send(command: "device_map")

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        // Resolve effective format: --json flag is shorthand for --format json
        let effectiveFormat = format ?? (json ? .json : .text)

        let content: String
        switch effectiveFormat {
        case .text:
            content = renderText(response.data?.value)
        case .json:
            content = renderJSON(response.data?.value)
        case .md:
            content = renderMarkdown(response.data?.value)
        case .agent:
            content = renderAgent(response.data?.value)
        }

        if let output {
            let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            try content.write(to: url, atomically: true, encoding: .utf8)
            let bytes = content.utf8.count
            let sizeStr = bytes > 1024 ? "\(bytes / 1024)KB" : "\(bytes)B"
            print("Wrote \(effectiveFormat) device map to \(url.path) (\(sizeStr))")
        } else {
            print(content)
        }
    }

    // MARK: - Text (original tree format)

    private func renderText(_ value: Any?) -> String {
        guard let data = value as? [String: Any] else { return "No data returned." }
        var lines: [String] = []

        if let stats = data["stats"] as? [String: Any] {
            let total = stats["total"] as? Int ?? 0
            let reachable = stats["reachable"] as? Int ?? 0
            lines.append("Device Map (\(total) devices, \(reachable) reachable)")
            if let byType = stats["by_semantic_type"] as? [String: Int] {
                for (type, count) in byType.sorted(by: { $0.value > $1.value }) {
                    lines.append("  \(type): \(count)")
                }
            }
            lines.append("")
        }

        if let note = data["disambiguation_note"] as? String {
            lines.append("Note: \(note)")
            lines.append("")
        }

        for home in data["homes"] as? [[String: Any]] ?? [] {
            lines.append(home["name"] as? String ?? "Unknown")
            for zone in home["zones"] as? [[String: Any]] ?? [] {
                lines.append("  \(zone["name"] as? String ?? "Unknown")")
                for room in zone["rooms"] as? [[String: Any]] ?? [] {
                    let devices = room["devices"] as? [[String: Any]] ?? []
                    lines.append("    \(room["name"] as? String ?? "Unknown") (\(devices.count) devices)")
                    for dev in devices {
                        let nameStr = dev["display_name"] as? String ?? dev["name"] as? String ?? "?"
                        let semType = dev["semantic_type"] as? String ?? "?"
                        let summary = dev["state_summary"] as? String ?? ""
                        let reachable = dev["reachable"] as? Bool ?? false
                        let prefix = reachable ? "+" : "-"
                        let stateStr = summary.isEmpty || summary == "unknown" ? "" : " — \(summary)"
                        lines.append("      \(prefix) \(nameStr) [\(semType)]\(stateStr)")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - JSON (full)

    private func renderJSON(_ value: Any?) -> String {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return "null" }
        return string
    }

    // MARK: - Agent JSON

    /// Produces a flat, LLM-agent-optimized JSON structure focused on disambiguation.
    /// Each device includes display_name, id, room, type, controls, and state —
    /// enough for an LLM to resolve "turn off the overhead" to the right UUID
    /// and know whether it supports brightness or just on/off.
    private func renderAgent(_ value: Any?) -> String {
        guard let data = value as? [String: Any],
              let homes = data["homes"] as? [[String: Any]]
        else { return "[]" }

        var devices: [[String: Any]] = []

        for home in homes {
            let homeName = home["name"] as? String ?? ""
            for zone in home["zones"] as? [[String: Any]] ?? [] {
                let zoneName = zone["name"] as? String ?? ""
                for room in zone["rooms"] as? [[String: Any]] ?? [] {
                    let roomName = room["name"] as? String ?? ""
                    for dev in room["devices"] as? [[String: Any]] ?? [] {
                        var entry: [String: Any] = [
                            "display_name": dev["display_name"] as? String ?? dev["name"] as? String ?? "?",
                            "id": dev["id"] as? String ?? "",
                            "room": roomName,
                            "type": dev["semantic_type"] as? String ?? "other",
                            "controls": dev["controllable"] as? [String] ?? [],
                            "state": dev["state_summary"] as? String ?? "unknown",
                        ]
                        if let reachable = dev["reachable"] as? Bool, !reachable {
                            entry["unreachable"] = true
                        }
                        // Include home/zone only when there are multiple homes
                        if homes.count > 1 {
                            entry["home"] = homeName
                        }
                        if zoneName != "(Unzoned)" {
                            entry["zone"] = zoneName
                        }
                        devices.append(entry)
                    }
                }
            }
        }

        // Wrap with minimal metadata
        var result: [String: Any] = [
            "device_count": devices.count,
            "devices": devices,
        ]
        if let stats = data["stats"] as? [String: Any],
           let byType = stats["by_semantic_type"] as? [String: Int]
        {
            result["by_type"] = byType
        }
        result["note"] = "Use 'id' for unambiguous control. 'type' distinguishes lighting (dimmable) from power (on/off only)."

        guard JSONSerialization.isValidJSONObject(result),
              let jsonData = try? JSONSerialization.data(
                  withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: jsonData, encoding: .utf8)
        else { return "[]" }
        return string
    }

    // MARK: - Markdown

    private func renderMarkdown(_ value: Any?) -> String {
        guard let data = value as? [String: Any] else { return "# Device Map\n\nNo data." }
        var md: [String] = []

        md.append("# HomeClaw Device Map")
        md.append("")

        // Summary
        if let stats = data["stats"] as? [String: Any] {
            let total = stats["total"] as? Int ?? 0
            let reachable = stats["reachable"] as? Int ?? 0
            let unreachable = total - reachable
            md.append("## Summary")
            md.append("")
            md.append("- **Total devices:** \(total)")
            md.append("- **Reachable:** \(reachable)")
            md.append("- **Unreachable:** \(unreachable)")
            md.append("")

            if let byType = stats["by_semantic_type"] as? [String: Int] {
                md.append("| Type | Count |")
                md.append("|------|-------|")
                for (type, count) in byType.sorted(by: { $0.value > $1.value }) {
                    md.append("| \(type) | \(count) |")
                }
                md.append("")
            }
        }

        // Homes
        for home in data["homes"] as? [[String: Any]] ?? [] {
            md.append("## \(home["name"] as? String ?? "Unknown")")
            md.append("")

            for zone in home["zones"] as? [[String: Any]] ?? [] {
                let zoneName = zone["name"] as? String ?? "Unknown"
                let heading = zoneName == "(Unzoned)" ? "Other Rooms" : zoneName
                md.append("### \(heading)")
                md.append("")

                for room in zone["rooms"] as? [[String: Any]] ?? [] {
                    let roomName = room["name"] as? String ?? "Unknown"
                    let devices = room["devices"] as? [[String: Any]] ?? []
                    md.append("#### \(roomName)")
                    md.append("")
                    md.append("| Device | ID | Type | State | Controls |")
                    md.append("|--------|----|------|-------|----------|")

                    for dev in devices {
                        let name = dev["display_name"] as? String ?? dev["name"] as? String ?? "?"
                        let id = dev["id"] as? String ?? ""
                        let shortID = String(id.prefix(8))
                        let semType = dev["semantic_type"] as? String ?? "other"
                        let state = dev["state_summary"] as? String ?? "unknown"
                        let reachable = dev["reachable"] as? Bool ?? false
                        let controls = (dev["controllable"] as? [String] ?? [])
                            .filter { $0 != "identify" }
                            .joined(separator: ", ")

                        let stateStr = reachable ? state : "**unreachable**"
                        md.append("| \(name) | `\(shortID)` | \(semType) | \(stateStr) | \(controls) |")
                    }
                    md.append("")
                }
            }
        }

        if let ts = data["generated_at"] as? String {
            md.append("---")
            md.append("Generated: \(ts)")
            md.append("")
        }

        return md.joined(separator: "\n")
    }
}
