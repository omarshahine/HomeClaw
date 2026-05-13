import ArgumentParser
import Foundation

struct Automations: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "automations",
        abstract: "Manage HomeKit automations (event triggers)",
        subcommands: [
            ListAutomations.self,
            GetAutomation.self,
            CreateAutomation.self,
            CreateTimeAutomation.self,
            DeleteAutomation.self,
            EnableAutomation.self,
            DisableAutomation.self,
            RewireAutomation.self,
            AddAutomationCondition.self,
        ],
        defaultSubcommand: ListAutomations.self
    )
}

// MARK: - List

struct ListAutomations: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all HomeKit automations"
    )

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: String] = [:]
        if let home { args["home_id"] = home }

        let response = try SocketClient.send(command: "list_automations", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }

        guard let automations = response.data?.value as? [[String: Any]], !automations.isEmpty else {
            print("No automations found.")
            return
        }

        for auto in automations {
            let name = auto["name"] as? String ?? "Unknown"
            let enabled = auto["enabled"] as? Bool ?? false
            let summary = auto["event_summary"] as? String ?? ""
            let scenes = auto["scenes"] as? [String] ?? []
            let status = enabled ? "enabled" : "disabled"
            let sceneStr = scenes.joined(separator: ", ")
            print("  [\(status)] \(name)")
            if !summary.isEmpty { print("    Event: \(summary)") }
            if !sceneStr.isEmpty { print("    Scene: \(sceneStr)") }
        }

        print("\n\(automations.count) automation(s)")
    }
}

// MARK: - Get

struct GetAutomation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show details of a HomeKit automation"
    )

    @Argument(help: "Automation name or UUID")
    var id: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: String] = ["id": id]
        if let home { args["home_id"] = home }

        let response = try SocketClient.send(command: "get_automation", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }

        guard let result = response.data?.value as? [String: Any] else {
            print("No automation data returned.")
            return
        }

        let name = result["name"] as? String ?? "Unknown"
        let enabled = result["enabled"] as? Bool ?? false
        let homeName = result["home"] as? String ?? "?"

        print("\(name) [\(enabled ? "enabled" : "disabled")]")
        print("Home: \(homeName)")

        if let events = result["events"] as? [[String: Any]] {
            print("\nEvents:")
            for event in events {
                let accessory = event["accessory"] as? String ?? "?"
                let pressType = event["press_type"] as? String ?? "?"
                let serviceIndex = event["service_index"] as? Int
                var line = "  \(accessory): \(pressType)"
                if let idx = serviceIndex { line += " (button \(idx))" }
                print(line)
            }
        }

        if let actionSets = result["action_sets"] as? [[String: Any]] {
            print("\nScenes:")
            for scene in actionSets {
                let sceneName = scene["name"] as? String ?? "?"
                let actionCount = scene["action_count"] as? Int ?? 0
                print("  \(sceneName) (\(actionCount) action(s))")
            }
        }
    }
}

// MARK: - Create

struct CreateAutomation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create an automation triggered by a characteristic change (button press, motion, contact, occupancy, etc.)"
    )

    @Option(name: .long, help: "Name for the automation")
    var name: String

    @Option(name: .long, help: "Trigger accessory name or UUID")
    var accessory: String

    @Option(name: .long, help: "Scene name or UUID to trigger (alternative to --action)")
    var scene: String?

    @Option(name: .long, parsing: .upToNextOption, help: "Inline action as 'accessory:property:value' (repeatable, alternative to --scene). Accessory names with colons are not supported; use the MCP actions array instead.")
    var action: [String] = []

    @Option(name: .long, help: "Press type: single, double, or long (default: single). For button triggers only; mutually exclusive with --characteristic.")
    var press: String = "single"

    @Option(name: .long, help: "Characteristic to trigger on (e.g., motion_detected, contact_state, occupancy_detected). Mutually exclusive with --press.")
    var characteristic: String?

    @Option(name: .long, help: "Value that triggers the automation (e.g., true, false, 1, 0). Required when --characteristic is set.")
    var triggerValue: String?

    @Option(name: .long, help: "Button index for multi-button accessories (e.g., 1 or 2). For button triggers only.")
    var serviceIndex: Int?

    @Option(name: .long, help: "Comma-separated weekdays the automation may fire on: mon,tue,wed,thu,fri,sat,sun (or numeric 1-7 where 1=Sun). When omitted, the automation fires every day.")
    var days: String?

    @Option(name: .long, parsing: .upToNextOption, help: "Extra characteristic predicate ANDed into the trigger as 'accessory:property:value' (repeatable). Example: 'Front Door:contact_state:0'. Note: accessory names containing colons are not supported via --condition; use the MCP conditions array instead.")
    var condition: [String] = []

    @Option(name: .long, parsing: .upToNextOption, help: "Sun-relative time predicate (repeatable): trigger only fires after the given event. Format: '<sunrise|sunset>[±N]' where N is minutes (e.g. 'sunset-30'). Offsets >1440 (24h) are rejected. Implies weekday auto-fill if --days is omitted.")
    var timeAfter: [String] = []

    @Option(name: .long, parsing: .upToNextOption, help: "Sun-relative time predicate (repeatable): trigger only fires before the given event. Format: '<sunrise|sunset>[±N]' where N is minutes (e.g. 'sunrise+15'). Offsets >1440 (24h) are rejected. Implies weekday auto-fill if --days is omitted.")
    var timeBefore: [String] = []

    @Option(name: .long, help: "Auto-revert the trigger's actions after this many seconds via HMDurationEvent (1-86400). Useful for motion-triggered lights that should turn off again after a delay.")
    var duration: Int?

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview changes without creating")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        guard scene != nil || !action.isEmpty else {
            throw ValidationError("Either --scene or --action is required")
        }

        var args: [String: Any] = [
            "name": name,
            "accessory_id": accessory,
            "dry_run": dryRun,
        ]

        if let characteristic {
            // Generic characteristic trigger mode
            guard press == "single" else {
                throw ValidationError("--press and --characteristic are mutually exclusive")
            }
            guard let triggerValue else {
                throw ValidationError("--trigger-value is required when --characteristic is set")
            }
            args["characteristic"] = characteristic
            args["trigger_value"] = triggerValue
        } else {
            // Button press trigger mode
            let pressType: Int
            switch press.lowercased() {
            case "single", "0": pressType = 0
            case "double", "1": pressType = 1
            case "long", "2": pressType = 2
            default: throw ValidationError("Invalid press type '\(press)'. Use: single, double, or long")
            }
            args["press_type"] = pressType
        }

        if let scene {
            args["scene_id"] = scene
        } else {
            // Parse inline actions from "accessory:property:value" format.
            // Shared with create-time via `parseActionRow` so whitespace handling
            // matches `--condition` (trim per part, reject empty).
            args["actions"] = try action.map { try Self.parseActionRow($0) }
        }

        if let serviceIndex { args["service_index"] = serviceIndex }

        if let days {
            args["weekdays"] = try Self.parseWeekdays(days)
        }

        if !condition.isEmpty {
            args["conditions"] = try condition.map { try Self.parseConditionRow($0) }
        }

        if !timeAfter.isEmpty {
            args["time_after"] = try timeAfter.map { try Self.validateTimeSpec($0, flag: "--time-after") }
        }
        if !timeBefore.isEmpty {
            args["time_before"] = try timeBefore.map { try Self.validateTimeSpec($0, flag: "--time-before") }
        }

        if let duration {
            guard (1...86400).contains(duration) else {
                throw ValidationError(
                    "--duration must be a positive integer between 1 and 86400 (24 hours)"
                )
            }
            args["duration_seconds"] = duration
        }

        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "create_automation", args: args)

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
        let autoName = result["name"] as? String ?? name
        let accessoryName = result["accessory"] as? String ?? "?"
        let triggerType = result["trigger_type"] as? String ?? "button"
        let actionCount = result["action_count"] as? Int
        let isInline = result["inline_actions"] as? Bool ?? false

        let triggerDescription: String
        if triggerType == "button" {
            let pressName = result["press_type"] as? String ?? "?"
            triggerDescription = "\(accessoryName) \(pressName)"
        } else {
            let charName = result["characteristic"] as? String ?? "?"
            let charValue = result["trigger_value"] as? String ?? "?"
            triggerDescription = "\(accessoryName) \(charName) = \(charValue)"
        }

        if isDryRun {
            print("DRY RUN — would create automation '\(autoName)'")
            print("  Trigger: \(triggerDescription)")
            if isInline, let actions = result["actions"] as? [[String: String]] {
                print("  Actions:")
                for a in actions {
                    let acc = a["accessory"] ?? "?"
                    let char = a["characteristic"] ?? "?"
                    let val = a["value"] ?? "?"
                    print("    \(acc): \(char) = \(val)")
                }
            } else if let sceneName = result["scene"] as? String {
                print("  Scene: \(sceneName)")
            }
            Self.printPredicateFields(from: result)
            if let durationSeconds = result["duration_seconds"] as? Int {
                print("  Auto-off: \(Self.formatDuration(durationSeconds))")
            }
        } else {
            if isInline {
                print("Created automation '\(autoName)' with \(actionCount ?? 0) inline action(s)")
                print("  \(triggerDescription) → \(actionCount ?? 0) action(s)")
            } else {
                let sceneName = result["scene"] as? String ?? "?"
                print("Created automation '\(autoName)'")
                print("  \(triggerDescription) → \(sceneName)")
            }
            Self.printPredicateFields(from: result)
            if let durationSeconds = result["duration_seconds"] as? Int {
                print("  Auto-off: \(Self.formatDuration(durationSeconds))")
            }
        }
    }

    /// Format an array of HomeKit weekday numbers (1=Sun ... 7=Sat) as a comma-separated label.
    static func formatWeekdays(_ weekdays: [Int]) -> String {
        let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return weekdays.compactMap { (1...7).contains($0) ? names[$0] : nil }.joined(separator: ",")
    }

    /// Validate a `--time-after` / `--time-before` spec. Format: `<sunrise|sunset>[±N]`.
    /// Mirrors `TimeCondition.parse` in HomeKitManager but throws CLI-shaped errors
    /// pointing at the offending flag. Defence-in-depth: SocketServer re-validates.
    static func validateTimeSpec(_ raw: String, flag: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard !lower.isEmpty else {
            throw ValidationError("\(flag) value is empty. Use 'sunrise', 'sunset', or '<sun-event>±<minutes>'.")
        }

        let rest: String
        if lower.hasPrefix("sunrise") {
            rest = String(lower.dropFirst("sunrise".count))
        } else if lower.hasPrefix("sunset") {
            rest = String(lower.dropFirst("sunset".count))
        } else {
            throw ValidationError("Invalid \(flag) '\(raw)'. Sun event must be 'sunrise' or 'sunset' (noon/midnight not supported).")
        }

        if rest.isEmpty { return lower }

        guard let sign = rest.first, sign == "+" || sign == "-" else {
            throw ValidationError("Invalid \(flag) '\(raw)'. Offset must start with + or - (e.g. 'sunset-30').")
        }
        let numStr = String(rest.dropFirst())
        guard !numStr.isEmpty else {
            throw ValidationError("Invalid \(flag) '\(raw)'. Missing offset minutes after '\(sign)'.")
        }
        guard let magnitude = Int(numStr), magnitude >= 0 else {
            throw ValidationError("Invalid \(flag) '\(raw)'. Offset must be a non-negative integer number of minutes.")
        }
        if magnitude > 1440 {
            throw ValidationError("Invalid \(flag) '\(raw)'. Offsets larger than 1440 minutes (24h) are rejected — that's almost certainly a typo; use --days for weekday gating.")
        }
        return lower
    }

    /// Parse `--days mon,tue,...` (or numeric `1-7` where 1=Sun) into the HomeKit
    /// weekday-number array. Throws a CLI-shaped error pointing at the offending token.
    /// Shared by `create` and `create-time` so both surfaces have identical day semantics.
    static func parseWeekdays(_ days: String) throws -> [Int] {
        let dayMap: [String: Int] = [
            "sun": 1, "sunday": 1,
            "mon": 2, "monday": 2,
            "tue": 3, "tuesday": 3,
            "wed": 4, "wednesday": 4,
            "thu": 5, "thursday": 5,
            "fri": 6, "friday": 6,
            "sat": 7, "saturday": 7,
        ]
        var weekdays: [Int] = []
        for raw in days.split(separator: ",") {
            let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if let n = dayMap[key] { weekdays.append(n) }
            else if let n = Int(key), (1...7).contains(n) { weekdays.append(n) }
            else { throw ValidationError("Invalid day '\(raw)'. Use mon/tue/wed/thu/fri/sat/sun or 1-7 (1=Sun)") }
        }
        return Array(Swift.Set(weekdays)).sorted()
    }

    /// Parse a `--condition` row string in `accessory:property:value` shape into the
    /// dict format the socket layer expects. Throws CLI-shaped ValidationErrors so
    /// malformed input fails before hitting HomeKit. Shared by `create` and `create-time`.
    static func parseConditionRow(_ raw: String) throws -> [String: String] {
        let parts = raw.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            throw ValidationError("Invalid --condition '\(raw)'. Use 'accessory:property:value' (note: accessory names containing colons are not supported via --condition; use the MCP conditions array instead).")
        }
        let accessoryPart = parts[0].trimmingCharacters(in: .whitespaces)
        let propertyPart = parts[1].trimmingCharacters(in: .whitespaces)
        let valuePart = parts[2].trimmingCharacters(in: .whitespaces)
        guard !accessoryPart.isEmpty, !propertyPart.isEmpty, !valuePart.isEmpty else {
            throw ValidationError("Invalid --condition '\(raw)'. Each of accessory/property/value must be non-empty.")
        }
        return [
            "accessory": accessoryPart,
            "property": propertyPart,
            "value": valuePart,
        ]
    }

    /// Parse a `--action` row string in `accessory:property:value` shape into the
    /// dict format the socket layer expects. Mirrors `parseConditionRow`'s strictness
    /// (trim per part, reject empty) so `--action` and `--condition` have identical
    /// whitespace handling within the same command surface. Shared by `create` and `create-time`.
    static func parseActionRow(_ raw: String) throws -> [String: String] {
        let parts = raw.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            throw ValidationError("Invalid action format '\(raw)'. Use 'accessory:property:value' (note: accessory names containing colons are not supported via --action; use the MCP actions array instead).")
        }
        let accessoryPart = parts[0].trimmingCharacters(in: .whitespaces)
        let propertyPart = parts[1].trimmingCharacters(in: .whitespaces)
        let valuePart = parts[2].trimmingCharacters(in: .whitespaces)
        guard !accessoryPart.isEmpty, !propertyPart.isEmpty, !valuePart.isEmpty else {
            throw ValidationError("Invalid action format '\(raw)'. Each of accessory/property/value must be non-empty.")
        }
        return [
            "accessory": accessoryPart,
            "property": propertyPart,
            "value": valuePart,
        ]
    }

    /// CLI-side mirror of `HomeKitManager.TimeSpec.parse(_:)`. Implements the
    /// same rules so the CLI fails fast with friendly error messages before the
    /// socket round-trip. SocketServer re-validates via `TimeSpec.parse`; manager
    /// is the canonical source of truth. Keep these two in sync.
    ///
    /// Accepts: `HH:MM`, `sunrise`, `sunset`, `sunrise±N`, `sunset±N` (where N is
    /// minutes, ≤ 1440). Returns the canonical lowercase string we pass to the
    /// socket layer. Strict HH:MM (two digits each) so the user can't ambiguously
    /// type `12:5` and silently mean `12:50`.
    ///
    /// This layer's job is to surface CLI-shaped error messages that say `--time`
    /// not `time`. The SocketServer re-validates via `TimeSpec.parse` so direct
    /// socket clients can't bypass the format check, and the manager re-runs
    /// `TimeSpec.parse` at HomeKit-mutation time as the canonical source of truth.
    static func validateTimeOfDaySpec(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw ValidationError("--time value is empty. Use 'HH:MM' (e.g. '06:30'), 'sunrise', 'sunset', or '<sun-event>±<minutes>' (e.g. 'sunset-30').")
        }
        let lower = trimmed.lowercased()

        // HH:MM
        if lower.contains(":") {
            let parts = lower.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw ValidationError("Invalid --time '\(raw)'. Use 'HH:MM' (e.g. '06:30').")
            }
            let hourStr = String(parts[0])
            let minStr = String(parts[1])
            // Reject ambiguous widths so '12:5' doesn't silently become '12:50'.
            guard hourStr.count == 2 else {
                throw ValidationError("Invalid --time '\(raw)'. Hour must be exactly two digits (e.g. '06:30', not '6:30').")
            }
            guard minStr.count == 2 else {
                throw ValidationError("Invalid --time '\(raw)'. Minute must be exactly two digits (e.g. '06:05', not '06:5').")
            }
            guard let hour = Int(hourStr), (0...23).contains(hour) else {
                throw ValidationError("Invalid --time '\(raw)'. Hour must be 0-23.")
            }
            guard let minute = Int(minStr), (0...59).contains(minute) else {
                throw ValidationError("Invalid --time '\(raw)'. Minute must be 0-59.")
            }
            return String(format: "%02d:%02d", hour, minute)
        }

        // sunrise / sunset (with optional ±N offset). Inline-handle the
        // unknown-prefix case (e.g. `noon`, `midnight`, `dawn`) with a tailored
        // error listing all four valid `--time` forms. Once we know the prefix
        // is `sunrise` or `sunset`, forward to `validateTimeSpec` for offset
        // parsing — that path's existing error messages are correct for
        // sun-event-with-bad-offset cases.
        guard lower.hasPrefix("sunrise") || lower.hasPrefix("sunset") else {
            throw ValidationError("Invalid --time '\(raw)'. Use 'HH:MM' (e.g. '06:30'), 'sunrise', 'sunset', or '<sun-event>±<minutes>' (e.g. 'sunset-30').")
        }
        return try Self.validateTimeSpec(lower, flag: "--time")
    }

    /// Print the conditions / time conditions / weekdays portion of a create response.
    /// Centralised so dry-run and success paths render identically.
    static func printPredicateFields(from result: [String: Any]) {
        if let conditions = result["conditions"] as? [[String: String]], !conditions.isEmpty {
            print("  Conditions:")
            for c in conditions {
                let acc = c["accessory"] ?? "?"
                let prop = c["property"] ?? "?"
                let val = c["value"] ?? "?"
                print("    \(acc): \(prop) = \(val)")
            }
        }
        if let timeAfter = result["time_after"] as? [String], !timeAfter.isEmpty {
            print("  Only after: \(timeAfter.joined(separator: ", "))")
        }
        if let timeBefore = result["time_before"] as? [String], !timeBefore.isEmpty {
            print("  Only before: \(timeBefore.joined(separator: ", "))")
        }
        let autoFilled = result["weekdays_auto_filled"] as? Bool ?? false
        if let weekdays = result["weekdays"] as? [Int], !weekdays.isEmpty {
            if autoFilled {
                print("  Days: every day (auto-filled — iOS 15+ requires weekday gating on time-conditional automations)")
            } else {
                print("  Days: \(Self.formatWeekdays(weekdays))")
            }
        }
    }

    /// Format a duration in seconds as a short human label (e.g. `45s`, `5m`, `1h30m`).
    /// Matches the surfacing PR #50 added to `automations list/get` output.
    static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remSeconds = seconds % 60
        if minutes < 60 {
            return remSeconds == 0 ? "\(minutes)m" : "\(minutes)m\(remSeconds)s"
        }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        return remMinutes == 0 ? "\(hours)h" : "\(hours)h\(remMinutes)m"
    }
}

// MARK: - Create (time-of-day)

struct CreateTimeAutomation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-time",
        abstract: "Create an automation triggered by a time of day (clock or sunrise/sunset)",
        discussion: """
            Creates a HomeKit automation whose trigger event is a wall-clock time
            (HMCalendarEvent) or a sun-relative event (HMSignificantTimeEvent).

            --time values:
              HH:MM        Wall-clock time, 00:00-23:59 (e.g. 06:30, 17:45)
              sunrise      Fire at sunrise
              sunset       Fire at sunset
              sunrise+N    N minutes after sunrise (e.g. sunrise+15)
              sunrise-N    N minutes before sunrise
              sunset+N     N minutes after sunset
              sunset-N     N minutes before sunset (e.g. sunset-30)

            All predicate flags (--days, --condition, --time-after, --time-before,
            --duration) compose with --time the same way they do on `create`. Without
            --days, all 7 days are auto-filled — iOS 15+ marks time-conditional
            automations without weekday gating as "unreliable".

            EXAMPLES
              # Weekday morning coffee
              homeclaw-cli automations create-time \\
                --name "Coffee Maker" --time "06:30" \\
                --days mon,tue,wed,thu,fri \\
                --action "Coffee Maker:power:1"

              # Sunset porch light with 1-hour auto-off
              homeclaw-cli automations create-time \\
                --name "Porch Lights" --time "sunset-30" \\
                --duration 3600 \\
                --scene "Porch On"

              # Sunset + occupancy condition
              homeclaw-cli automations create-time \\
                --name "Welcome Home Glow" --time "sunset" \\
                --condition "Front Door:occupancy_detected:true" \\
                --days mon,tue,wed,thu,fri \\
                --scene "Welcome"
            """
    )

    @Option(name: .long, help: "Name for the automation")
    var name: String

    @Option(name: .long, help: "Time of day the automation fires: 'HH:MM' (e.g. '06:30'), 'sunrise', 'sunset', or '<sun-event>±<minutes>' (e.g. 'sunset-30', 'sunrise+15').")
    var time: String

    @Option(name: .long, help: "Scene name or UUID to trigger (alternative to --action)")
    var scene: String?

    @Option(name: .long, parsing: .upToNextOption, help: "Inline action as 'accessory:property:value' (repeatable, alternative to --scene). Accessory names with colons are not supported; use the MCP actions array instead.")
    var action: [String] = []

    @Option(name: .long, help: "Comma-separated weekdays the automation may fire on: mon,tue,wed,thu,fri,sat,sun (or numeric 1-7 where 1=Sun). When omitted, all 7 days are auto-filled — iOS 15+ requires weekday gating on time-conditional automations.")
    var days: String?

    @Option(name: .long, parsing: .upToNextOption, help: "Extra characteristic predicate ANDed into the trigger as 'accessory:property:value' (repeatable). Example: 'Front Door:occupancy_detected:true'. Note: accessory names containing colons are not supported via --condition; use the MCP conditions array instead.")
    var condition: [String] = []

    @Option(name: .long, parsing: .upToNextOption, help: "Sun-relative time predicate (repeatable): trigger only fires after the given event. Format: '<sunrise|sunset>[±N]' where N is minutes. Composes with --time (e.g. --time 06:30 --time-after sunrise means '06:30, but only after sunrise').")
    var timeAfter: [String] = []

    @Option(name: .long, parsing: .upToNextOption, help: "Sun-relative time predicate (repeatable): trigger only fires before the given event. Same format as --time-after.")
    var timeBefore: [String] = []

    @Option(name: .long, help: "Auto-revert the trigger's actions after this many seconds via HMDurationEvent (1-86400). Useful for sunset porch lights that should turn off after an hour.")
    var duration: Int?

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview changes without creating")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        guard scene != nil || !action.isEmpty else {
            throw ValidationError("Either --scene or --action is required")
        }

        let canonicalTime = try CreateAutomation.validateTimeOfDaySpec(time)

        var args: [String: Any] = [
            "name": name,
            "time": canonicalTime,
            "dry_run": dryRun,
        ]

        if let scene {
            args["scene_id"] = scene
        } else {
            args["actions"] = try action.map { try CreateAutomation.parseActionRow($0) }
        }

        if let days {
            args["weekdays"] = try CreateAutomation.parseWeekdays(days)
        }

        if !condition.isEmpty {
            args["conditions"] = try condition.map { try CreateAutomation.parseConditionRow($0) }
        }

        if !timeAfter.isEmpty {
            args["time_after"] = try timeAfter.map { try CreateAutomation.validateTimeSpec($0, flag: "--time-after") }
        }
        if !timeBefore.isEmpty {
            args["time_before"] = try timeBefore.map { try CreateAutomation.validateTimeSpec($0, flag: "--time-before") }
        }

        if let duration {
            guard (1...86400).contains(duration) else {
                throw ValidationError(
                    "--duration must be a positive integer between 1 and 86400 (24 hours)"
                )
            }
            args["duration_seconds"] = duration
        }

        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "create_time_automation", args: args)

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
        let autoName = result["name"] as? String ?? name
        let resolvedTime = result["time"] as? String ?? canonicalTime
        let actionCount = result["action_count"] as? Int
        let isInline = result["inline_actions"] as? Bool ?? false

        if isDryRun {
            print("DRY RUN — would create automation '\(autoName)'")
            print("  Trigger: at \(resolvedTime)")
            if isInline, let actions = result["actions"] as? [[String: String]] {
                print("  Actions:")
                for a in actions {
                    let acc = a["accessory"] ?? "?"
                    let char = a["characteristic"] ?? "?"
                    let val = a["value"] ?? "?"
                    print("    \(acc): \(char) = \(val)")
                }
            } else if let sceneName = result["scene"] as? String {
                print("  Scene: \(sceneName)")
            }
            CreateAutomation.printPredicateFields(from: result)
            if let durationSeconds = result["duration_seconds"] as? Int {
                print("  Auto-off: \(CreateAutomation.formatDuration(durationSeconds))")
            }
        } else {
            if isInline {
                print("Created automation '\(autoName)' with \(actionCount ?? 0) inline action(s)")
                print("  at \(resolvedTime) → \(actionCount ?? 0) action(s)")
            } else {
                let sceneName = result["scene"] as? String ?? "?"
                print("Created automation '\(autoName)'")
                print("  at \(resolvedTime) → \(sceneName)")
            }
            CreateAutomation.printPredicateFields(from: result)
            if let durationSeconds = result["duration_seconds"] as? Int {
                print("  Auto-off: \(CreateAutomation.formatDuration(durationSeconds))")
            }
        }
    }
}

// MARK: - Delete

struct DeleteAutomation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a HomeKit automation"
    )

    @Argument(help: "Automation name or UUID")
    var id: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview without deleting")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        var args: [String: Any] = ["id": id, "dry_run": dryRun]
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "delete_automation", args: args)

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
        let autoName = result["name"] as? String ?? "?"

        if isDryRun {
            let sceneCount = result["scene_count"] as? Int ?? 0
            print("DRY RUN — would delete automation '\(autoName)' (\(sceneCount) linked scene(s))")
        } else {
            print("Deleted automation '\(autoName)'")
        }
    }
}

// MARK: - Enable / Disable

struct EnableAutomation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable a HomeKit automation"
    )

    @Argument(help: "Automation name or UUID")
    var id: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    func run() throws {
        var args: [String: Any] = ["id": id, "enabled": true]
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "enable_automation", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if let result = response.data?.value as? [String: Any],
           let name = result["name"] as? String
        {
            print("Enabled automation '\(name)'")
        } else {
            print("Automation enabled.")
        }
    }
}

struct DisableAutomation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable a HomeKit automation"
    )

    @Argument(help: "Automation name or UUID")
    var id: String

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    func run() throws {
        var args: [String: Any] = ["id": id, "enabled": false]
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "enable_automation", args: args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if let result = response.data?.value as? [String: Any],
           let name = result["name"] as? String
        {
            print("Disabled automation '\(name)'")
        } else {
            print("Automation disabled.")
        }
    }
}

// MARK: - Rewire (mutate attached scenes in place)

struct RewireAutomation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rewire",
        abstract:
            "Add or remove scenes attached to an existing automation in place (preserves trigger UUID)"
    )

    @Argument(help: "Automation name or UUID")
    var id: String

    @Option(name: .long, parsing: .singleValue, help: "Scene name or UUID to attach (repeatable)")
    var addScene: [String] = []

    @Option(
        name: .long, parsing: .singleValue, help: "Scene name or UUID to detach (repeatable)")
    var removeScene: [String] = []

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview without modifying the automation")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        guard !addScene.isEmpty || !removeScene.isEmpty else {
            throw ValidationError("Provide at least one --add-scene or --remove-scene")
        }

        var args: [String: Any] = [
            "id": id,
            "add_scenes": addScene,
            "remove_scenes": removeScene,
            "dry_run": dryRun,
        ]
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "update_automation", args: args)
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
        let autoName = result["name"] as? String ?? id
        let before = (result["before"] as? [String]) ?? []
        let toAdd = (result["to_add"] as? [String]) ?? []
        let toRemove = (result["to_remove"] as? [String]) ?? []
        let warnings = (result["warnings"] as? [String]) ?? []

        if isDryRun {
            print("DRY RUN — \(autoName)")
            print("  Currently attached: \(before.joined(separator: ", "))")
            print("  Would add:    \(toAdd.joined(separator: ", "))")
            print("  Would remove: \(toRemove.joined(separator: ", "))")
        } else {
            let after = (result["after"] as? [String]) ?? []
            print("Rewired '\(autoName)'")
            print("  Before: \(before.joined(separator: ", "))")
            print("  After:  \(after.joined(separator: ", "))")
        }

        if !warnings.isEmpty {
            print("\nWarnings:")
            for w in warnings { print("  ⚠ \(w)") }
        }
    }
}

// MARK: - Add Condition (modify-in-place)

/// Append a characteristic condition (ANDed) to an existing automation's trigger predicate.
/// Preserves the trigger UUID so physical button bindings, Siri references, and any other
/// UUID-keyed integrations survive the modification (the reason this exists rather than
/// "delete + recreate with extra flags"). See `HomeKitManager.addAutomationCondition`
/// for the predicate-combine strategy (flatten-at-write) and the failure semantics.
struct AddAutomationCondition: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-condition",
        abstract:
            "Add a characteristic condition (ANDed) to an existing automation in place (preserves trigger UUID)"
    )

    @Argument(help: "Automation name or UUID")
    var id: String

    @Option(name: .long, help: "Accessory name or UUID for the new condition")
    var accessory: String

    @Option(name: .long, help: "Characteristic name (e.g., contact_state, occupancy_detected, power)")
    var property: String

    @Option(name: .long, help: "Required value as string (e.g., 'true', '0', '50'); uses exact match (==)")
    var value: String

    @Option(name: .long, help: "Room name for accessory disambiguation when multiple accessories share a name (optional)")
    var room: String?

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview without modifying the automation")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func validate() throws {
        // ArgumentParser already enforces presence of @Option/@Argument, but it doesn't
        // catch empty strings (e.g. --accessory '' or a positional argument that's just
        // whitespace). Reject those here so the user gets a CLI ValidationError before
        // we open the socket and round-trip to HomeKitManager.
        if id.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("Automation id/name must be non-empty")
        }
        if accessory.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("--accessory must be non-empty")
        }
        if property.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("--property must be non-empty")
        }
        if value.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("--value must be non-empty")
        }
        if let room, room.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("--room must be non-empty when provided")
        }
    }

    func run() throws {
        var args: [String: Any] = [
            "id": id,
            "accessory": accessory,
            "property": property,
            "value": value,
            "dry_run": dryRun,
        ]
        if let room { args["room"] = room }
        if let home { args["home_id"] = home }

        let response = try SocketClient.sendAny(command: "add_automation_condition", args: args)
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
        let autoName = result["name"] as? String ?? id
        let accessoryName = result["accessory"] as? String ?? accessory
        let propertyName = result["property"] as? String ?? property
        let valueStr = result["value"] as? String ?? value
        let count = result["condition_count_after"] as? Int
        // Only echo the room when HomeKitManager included it in the result —
        // it does so only when the room hint actually scoped the lookup (the
        // name-based path was taken). UUID lookups omit it because the room
        // would be misleading.
        let roomSuffix: String
        if let room = result["room"] as? String {
            roomSuffix = " (in room \(room))"
        } else {
            roomSuffix = ""
        }

        if isDryRun {
            print("DRY RUN — would add condition to '\(autoName)': \(accessoryName)\(roomSuffix).\(propertyName) = \(valueStr)")
        } else {
            print("Added condition to '\(autoName)': \(accessoryName)\(roomSuffix).\(propertyName) = \(valueStr)")
        }
        if let count {
            print("  Trigger now has \(count) condition(s)")
        }
    }
}
