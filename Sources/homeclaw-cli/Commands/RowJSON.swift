import ArgumentParser
import Foundation

/// JSON forms of action and condition rows (#87).
///
/// The positional `accessory:property:value` grammar of `--action` / `--condition`
/// is full: it splits on the first two colons only (`maxSplits: 2`) so a value like
/// `22:30` survives, which leaves no room for a fourth field. Rows that need more
/// than the three positional parts, such as a service selector to pick one gang of a
/// multi-gang accessory, use a JSON object instead: `--action-json` /
/// `--condition-json` on the CLI, and the `actions` array of an `import-scene` /
/// `update-scene` file.
///
/// Rows travel to the app as `[String: String]`, so `service_index` is carried as
/// text; a JSON integer is accepted and converted.
enum RowJSON {
    /// The optional keys that pick one service when the property exists on several.
    static let serviceSelectorKeys = ["service_name", "service_id", "service_index"]

    /// Keys an `--action-json` / `--condition-json` object may carry.
    static let flagRowKeys: Swift.Set<String> = Swift.Set(
        ["accessory", "property", "characteristic", "value", "room"] + serviceSelectorKeys
    )

    /// Parses one `--action-json` / `--condition-json` value into the row dict the
    /// socket layer expects. Strict: unknown keys (a typo such as `service-index`),
    /// non-string values, empty strings, and a `service_index` that isn't a whole
    /// number of at least 1 are all rejected before anything is sent.
    static func parseFlagRow(_ raw: String, flag: String) throws -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else {
            throw ValidationError(
                "Invalid \(flag) '\(raw)'. Expected a JSON object such as "
                    + #"'{"accessory":"Covelight","property":"power","value":"false","service_index":2}'."#
            )
        }
        let unknown = Swift.Set(dict.keys).subtracting(flagRowKeys).sorted()
        guard unknown.isEmpty else {
            throw ValidationError(
                "Invalid \(flag): unknown key(s) \(unknown.joined(separator: ", ")). "
                    + "Allowed: \(flagRowKeys.sorted().joined(separator: ", ")).")
        }
        if dict["property"] != nil && dict["characteristic"] != nil {
            throw ValidationError("Invalid \(flag): give 'property' or its alias 'characteristic', not both.")
        }

        var row: [String: String] = [:]
        for (key, value) in dict {
            row[key == "characteristic" ? "property" : key] = try normalizedValue(value, key: key, context: flag)
        }
        for key in ["accessory", "property", "value"] where row[key] == nil {
            throw ValidationError("Invalid \(flag): missing required key '\(key)'.")
        }
        return row
    }

    /// Converts the `actions` array of an `import-scene` / `update-scene` file to
    /// string rows. Returns nil when `raw` isn't an array of objects. String values
    /// pass through untouched (so `get-scene --json` output round-trips exactly);
    /// the service selectors are validated and normalized; any other non-string
    /// value is an error naming the row and key.
    static func sceneActionRows(_ raw: Any?) throws -> [[String: String]]? {
        guard let array = raw as? [Any] else { return nil }
        var rows: [[String: String]] = []
        for (index, element) in array.enumerated() {
            guard let dict = element as? [String: Any] else { return nil }
            var row: [String: String] = [:]
            for (key, value) in dict {
                if serviceSelectorKeys.contains(key) {
                    row[key] = try normalizedValue(value, key: key, context: "actions[\(index)]")
                } else if let string = value as? String {
                    row[key] = string
                } else {
                    throw ValidationError("actions[\(index)].\(key) must be a string")
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// One field of a JSON row as the string the socket expects.
    private static func normalizedValue(_ value: Any, key: String, context: String) throws -> String {
        let isBool = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        if key == "service_index" {
            let text: String?
            if isBool {
                text = nil
            } else if let number = value as? NSNumber {
                text = (number as? Int).map(String.init)
            } else {
                text = value as? String
            }
            guard let text, let index = Int(text.trimmingCharacters(in: .whitespaces)), index >= 1 else {
                throw ValidationError("Invalid \(context): 'service_index' must be a whole number of at least 1, got \(value)")
            }
            return String(index)
        }
        guard !isBool, let string = value as? String else {
            throw ValidationError("Invalid \(context): '\(key)' must be a string")
        }
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw ValidationError("Invalid \(context): '\(key)' must be non-empty")
        }
        return trimmed
    }

    /// `Accessory` or `Accessory [service]` for human output, so a row that
    /// targets one gang says which.
    static func targetLabel(_ row: [String: String]) -> String {
        let accessory = row["accessory"] ?? "?"
        guard let service = row["service_name"], service != accessory else { return accessory }
        return "\(accessory) [\(service)]"
    }

    /// Prints a response's `warnings` array (ambiguous-service notices and the like).
    static func printWarnings(_ result: [String: Any]) {
        let warnings = result["warnings"] as? [String] ?? []
        guard !warnings.isEmpty else { return }
        print("\nWarnings:")
        for warning in warnings {
            print("  ⚠ \(warning)")
        }
    }
}
