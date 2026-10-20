import ArgumentParser
import Foundation

/// `automations migrate-actions`: plan (and with --apply, perform) replacing an
/// accessory's actions in the action sets automations run (issue #120).
///
/// Plan-only by default. This is a bulk edit across scenes that other automations
/// and Home app scene tiles may share, so writing needs an explicit `--apply`
/// rather than the usual `--dry-run` opt-out. Automation-owned hidden action sets
/// are never written: HomeKit requires an Apple-only entitlement for that, so they
/// come back `unsupported` with manual Apple Home steps.
struct MigrateAutomationActions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate-actions",
        abstract: "Plan moving an accessory's automation actions onto its replacement(s); --apply writes visible scenes only",
        discussion: """
            Finds every automation (or just --automation) whose action sets write to
            the old accessory, maps each action onto the new accessories by
            characteristic type, and reports per action set:

              visible_scene  a scene in the Home app's Scenes list. Editable in place
                             (UUID kept), but shared: editing it changes every
                             automation and scene tile that uses it.
              hidden         owned by one automation. Third-party apps cannot write
                             these (Apple's private SPI entitlement is required), so
                             they are always "unsupported" and come with manual Apple
                             Home steps. See docs/PRIVATE_API.md.

            Status per set: supported, unsupported, or blocked (a characteristic is
            missing on every replacement, ambiguous across services, or conflicts).
            Without --apply nothing is written. With --apply only supported visible
            scenes are written: new actions are added, old ones removed, and the
            scene is re-read and verified. Triggers are never changed.

            EXAMPLES
              homeclaw-cli automations migrate-actions \\
                --replace-accessory "Old Lamp=New Lamp"
              homeclaw-cli automations migrate-actions \\
                --replace-accessory "<old-uuid>=<new-uuid>,<other-new-uuid>" \\
                --automation "Evening" --json
            """
    )

    @Option(name: .long, help: "'<old>=<new>[,<new>...]': old accessory name or UUID (a UUID may name an accessory already removed), then one or more replacements. Names containing '=' or ',' are not supported; use UUIDs.")
    var replaceAccessory: String

    @Option(name: .long, help: "Limit to one automation (name or UUID)")
    var automation: String?

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Write supported visible scenes. Without it the command only plans.")
    var apply = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    struct Replacement: Equatable {
        let old: String
        let new: [String]
    }

    /// Parse `<old>=<new>[,<new>...]`. Throws ValidationError for malformed input.
    static func parseReplacement(_ raw: String) throws -> Replacement {
        let parts = raw.split(separator: "=", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw ValidationError("Invalid --replace-accessory '\(raw)'. Use '<old>=<new>[,<new>...]' (exactly one '=').")
        }
        let old = parts[0].trimmingCharacters(in: .whitespaces)
        guard !old.isEmpty else {
            throw ValidationError("Invalid --replace-accessory '\(raw)'. The old accessory before '=' is empty.")
        }
        let new = parts[1].split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !new.contains(where: \.isEmpty) else {
            throw ValidationError("Invalid --replace-accessory '\(raw)'. Every replacement after '=' must be non-empty.")
        }
        var seen = Swift.Set<String>()
        for item in new {
            guard seen.insert(item.lowercased()).inserted else {
                throw ValidationError("Invalid --replace-accessory '\(raw)'. Replacement '\(item)' is listed twice.")
            }
            guard item.caseInsensitiveCompare(old) != .orderedSame else {
                throw ValidationError("Invalid --replace-accessory '\(raw)'. '\(item)' cannot replace itself.")
            }
        }
        return Replacement(old: old, new: new)
    }

    func validate() throws {
        _ = try Self.parseReplacement(replaceAccessory)
        if let automation, automation.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("--automation must be non-empty when provided")
        }
    }

    func run() throws {
        let replacement = try Self.parseReplacement(replaceAccessory)
        var args: [String: Any] = [
            "old_accessory": replacement.old,
            "new_accessories": replacement.new,
            "apply": apply,
        ]
        if let automation { args["automation_id"] = automation }
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "migrate_automation_actions", args: args)
        guard response.success else {
            throw CommandFailure(response.error ?? "Unknown error")
        }
        let result = response.data?.value as? [String: Any] ?? [:]

        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
        } else {
            for line in Self.formatResult(result) { print(line) }
        }
        if let failure = Self.applyFailure(result) { throw CommandFailure(failure) }
    }

    /// A message when an --apply run failed or did not verify, so the exit code is
    /// nonzero even though the socket call itself succeeded.
    static func applyFailure(_ result: [String: Any]) -> String? {
        guard let summary = result["summary"] as? [String: Any], result["mode"] as? String == "apply" else { return nil }
        let failed = summary["failed"] as? Int ?? 0
        var unverified = 0
        for auto in result["automations"] as? [[String: Any]] ?? [] {
            for set in auto["action_sets"] as? [[String: Any]] ?? [] {
                guard let apply = set["apply"] as? [String: Any], apply["status"] as? String == "applied" else { continue }
                let verification = apply["verification"] as? [String: Any]
                if verification?["verified"] as? Bool != true || apply["error"] != nil { unverified += 1 }
            }
        }
        guard failed + unverified > 0 else { return nil }
        return "migrate-actions: \(failed) set(s) failed and \(unverified) applied set(s) did not verify; see the rollback blocks"
    }

    /// Readable rendering of a migrate-actions result.
    static func formatResult(_ result: [String: Any]) -> [String] {
        var lines: [String] = []
        let isApply = result["mode"] as? String == "apply"
        let old = result["old_accessory"] as? [String: Any] ?? [:]
        let oldLabel = (old["name"] as? String).map { "\($0) (\(old["id"] as? String ?? "?"))" }
            ?? "\(old["id"] as? String ?? "?") (not in home)"
        let news = (result["new_accessories"] as? [[String: Any]] ?? []).map {
            "\($0["name"] as? String ?? "?") (\($0["id"] as? String ?? "?"))"
        }
        lines.append(isApply ? "APPLY: migrate-actions" : "DRY RUN: migrate-actions (nothing written; pass --apply to write supported visible scenes)")
        lines.append("  Replace: \(oldLabel)")
        lines.append("  With:    \(news.joined(separator: ", "))")

        let automations = result["automations"] as? [[String: Any]] ?? []
        if automations.isEmpty {
            lines.append("")
            lines.append("No automation action sets write to the old accessory.")
        }
        for auto in automations {
            let enabled = auto["enabled"] as? Bool ?? false
            lines.append("")
            lines.append("\(auto["name"] as? String ?? "?") (\(auto["id"] as? String ?? "?")) [\(enabled ? "enabled" : "disabled")]")
            lines.append("  Trigger: \(auto["trigger_summary"] as? String ?? "?")"
                + ((auto["trigger_uses_old_accessory"] as? Bool ?? false) ? " (watches the old accessory; not changed)" : ""))
            for set in auto["action_sets"] as? [[String: Any]] ?? [] {
                lines.append(contentsOf: formatSet(set))
            }
        }

        if let unattached = result["unattached_scenes"] as? [[String: Any]], !unattached.isEmpty {
            lines.append("")
            lines.append("Scenes not used by any automation that also use the old accessory (edit with update-scene):")
            for scene in unattached {
                lines.append("  \(scene["name"] as? String ?? "?") (\(scene["id"] as? String ?? "?"))")
            }
        }

        if let summary = result["summary"] as? [String: Any] {
            lines.append("")
            var text = "\(summary["automations"] as? Int ?? 0) automation(s), \(summary["action_sets"] as? Int ?? 0) action set(s): "
                + "\(summary["supported"] as? Int ?? 0) supported, \(summary["unsupported"] as? Int ?? 0) unsupported, "
                + "\(summary["blocked"] as? Int ?? 0) blocked"
            if isApply {
                text += "; \(summary["applied"] as? Int ?? 0) applied, \(summary["verified"] as? Int ?? 0) verified, "
                    + "\(summary["failed"] as? Int ?? 0) failed"
            }
            lines.append(text)
        }
        let warnings = result["warnings"] as? [String] ?? []
        if !warnings.isEmpty {
            lines.append("")
            lines.append("Warnings:")
            for w in warnings { lines.append("  ! \(w)") }
        }
        return lines
    }

    static func formatSet(_ set: [String: Any]) -> [String] {
        var lines: [String] = []
        let classification = set["classification"] as? String ?? "?"
        let status = set["status"] as? String ?? "?"
        let name = sceneDisplayName(set["name"] as? String, id: set["id"] as? String)
        lines.append("  [\(status)] \(classification == "hidden" ? "hidden action set" : "scene '\(name)'") (\(set["id"] as? String ?? "?"))"
            + ((set["reason"] as? String).map { ": \($0)" } ?? ""))
        if let shared = set["shared_with"] as? [[String: Any]], !shared.isEmpty {
            lines.append("    Shared with: " + shared.map { $0["name"] as? String ?? "?" }.joined(separator: ", "))
        }
        for row in set["removals"] as? [[String: Any]] ?? [] {
            lines.append("    - remove \(row["accessory"] as? String ?? "?") \(row["characteristic"] as? String ?? "?") = \(valueText(row["value"]))")
        }
        for row in set["additions"] as? [[String: Any]] ?? [] {
            lines.append("    + add    \(row["accessory"] as? String ?? "?") \(row["characteristic"] as? String ?? "?") = \(valueText(row["value"]))"
                + ((row["service_type_changed"] as? Bool ?? false) ? " (different service type)" : ""))
        }
        for issue in set["issues"] as? [[String: Any]] ?? [] {
            let blocking = issue["blocking"] as? Bool ?? false
            lines.append("    \(blocking ? "x" : "~") \(issue["kind"] as? String ?? "?"): \(issue["detail"] as? String ?? "")")
        }
        if let steps = set["manual_steps"] as? [[String: Any]], !steps.isEmpty {
            lines.append("    Apple Home steps:")
            for step in steps { lines.append("      \(step["step"] as? Int ?? 0). \(step["text"] as? String ?? "")") }
        }
        if let apply = set["apply"] as? [String: Any] {
            var text = "    Apply: \(apply["status"] as? String ?? "?")"
            if let verification = apply["verification"] as? [String: Any] {
                text += (verification["verified"] as? Bool ?? false) ? ", verified" : ", NOT verified"
            }
            if let error = apply["error"] as? String { text += " (\(error))" }
            if let note = apply["note"] as? String { text += " [\(note)]" }
            lines.append(text)
        }
        return lines
    }

    private static func valueText(_ value: Any?) -> String {
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let s as String: return s
        case nil: return "?"
        default: return "\(value!)"
        }
    }
}
