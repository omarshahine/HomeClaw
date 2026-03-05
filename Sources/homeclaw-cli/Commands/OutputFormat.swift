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
