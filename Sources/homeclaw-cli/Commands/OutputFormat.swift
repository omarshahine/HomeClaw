import ArgumentParser
import Foundation

/// Returns true if the CLI should output JSON instead of human-readable text.
///
/// JSON output is used when any of these conditions are met:
/// 1. The `--json` flag is explicitly set
/// 2. The `OUTPUT_FORMAT` environment variable is set to `json`
/// 3. stdout is not a TTY (piped or captured by an agent)
///
/// Reference: https://justin.poehnelt.com/posts/rewrite-your-cli-for-ai-agents/
func shouldOutputJSON(_ flag: Bool) -> Bool {
    if flag { return true }
    if ProcessInfo.processInfo.environment["OUTPUT_FORMAT"]?.lowercased() == "json" {
        return true
    }
    return isatty(STDOUT_FILENO) == 0
}

/// Parses a duration shorthand (e.g. "1h", "30m", "2d") or ISO 8601 timestamp
/// into an ISO 8601 string suitable for the server's `since` filter.
/// Throws `ValidationError` for unrecognized formats instead of silently passing through.
func parseSinceValue(_ value: String) throws -> String {
    // Try ISO 8601 first
    if ISO8601DateFormatter().date(from: value) != nil {
        return value
    }

    // Try duration shorthand: Nh, Nm, Nd
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

    throw ValidationError("Unrecognized --since format: '\(value)'. Use ISO 8601 or duration (e.g. 1h, 30m, 2d)")
}

/// Validates a string argument against control character injection.
/// Rejects ASCII control characters below 0x20 (except common whitespace).
/// Returns nil if valid, or an error message if invalid.
func validateInput(_ value: String, label: String) -> String? {
    for scalar in value.unicodeScalars {
        if scalar.value < 0x20 && scalar.value != 0x09 && scalar.value != 0x0A && scalar.value != 0x0D {
            return "Invalid \(label): contains control character (U+\(String(format: "%04X", scalar.value)))"
        }
    }
    return nil
}
