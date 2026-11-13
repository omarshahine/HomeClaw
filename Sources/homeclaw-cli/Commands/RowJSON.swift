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
        ["accessory", "property", "characteristic", "value", "room", "operator"] + serviceSelectorKeys
    )

    /// Canonical comparison operators a condition row may carry.
    ///
    /// The CLI is an SPM target and cannot see the app's `ConditionComparison`, so it
    /// validates the spelling itself — the same defense-in-depth split the repo already
    /// uses for time specs (`validateTimeSpec` here, `TimeCondition.parse` in the app).
    /// SocketServer owns the authoritative parse and rejects anything this lets through
    /// that it does not recognize.
    static let comparisonOperators: [String] = ["==", "!=", "<", "<=", ">", ">="]

    /// Mnemonic spellings, mapped to the canonical symbol.
    static let comparisonOperatorAliases: [String: String] = [
        "eq": "==", "equals": "==", "equalto": "==",
        "ne": "!=", "neq": "!=", "notequalto": "!=",
        "lt": "<", "lessthan": "<",
        "lte": "<=", "le": "<=", "lessthanorequalto": "<=",
        "gt": ">", "greaterthan": ">",
        "gte": ">=", "ge": ">=", "greaterthanorequalto": ">=",
    ]

    /// Normalize an operator written as a symbol or a mnemonic to its canonical form.
    /// Returns nil for anything unrecognized so the caller fails loud instead of
    /// silently falling back to equality and shipping a different rule than asked for.
    static func normalizedComparisonOperator(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if comparisonOperators.contains(trimmed) { return trimmed }
        return comparisonOperatorAliases[trimmed]
    }

    /// True when the text is a plain decimal number: optional sign, digits, at most one dot.
    ///
    /// `Double(String)` also accepts `nan`, `inf` and hex floats such as `0x1p3`, which would
    /// let `"<inf"` be peeled into a comparison. Mirrors `ConditionComparison.isDecimalThreshold`.
    static func isDecimalThreshold(_ text: String) -> Bool {
        var digits = Substring(text)
        if digits.first == "+" || digits.first == "-" { digits = digits.dropFirst() }
        guard !digits.isEmpty else { return false }
        var sawDigit = false
        var sawDot = false
        for character in digits {
            if character >= "0", character <= "9" {
                sawDigit = true
            } else if character == "." {
                if sawDot { return false }
                sawDot = true
            } else {
                return false
            }
        }
        return sawDigit
    }

    /// Split a symbolic operator prefix off a CLI-supplied value: `"<30"` → (`"<"`, `"30"`).
    ///
    /// This mirrors the app's `ConditionComparison.splitValuePrefix` and must stay in step with
    /// it: the CLI validates before anything reaches the socket, so a divergence here rejects a
    /// row the app would accept, or sends a comparison the app then refuses.
    ///
    /// A prefix is only peeled when what follows is a number. A string value can legitimately
    /// begin with a comparison character (`"<none>"`), and splitting it would turn an equality
    /// row into a comparison the caller never asked for.
    static func splitComparisonPrefix(_ raw: String) -> (op: String, value: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes: [(String, String)] = [
            ("==", "=="), ("!=", "!="), ("<=", "<="), (">=", ">="), ("<", "<"), (">", ">"),
        ]
        for (prefix, op) in prefixes where trimmed.hasPrefix(prefix) {
            let remainder = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            // A bare operator still splits so the caller reports "operator but no value".
            if remainder.isEmpty { return (op, remainder) }
            let numericPart = remainder.hasSuffix("%") ? String(remainder.dropLast()) : remainder
            // Peel a boolean token too: `<on` is a mistaken threshold, and the app rejects it
            // with "on/off values only support == and !=". `<none>` is neither numeric nor a
            // token, so it stays a literal value.
            if RowJSON.isDecimalThreshold(numericPart) || RowJSON.isBooleanToken(remainder) {
                return (op, remainder)
            }
            return nil
        }
        return nil
    }

    /// On/off words that are never a valid operand for an ordered comparison.
    static func isBooleanToken(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on", "off", "true", "false": return true
        default: return false
        }
    }

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
        try validateOperator(in: &row, flag: flag)
        return row
    }

    /// Validate (and normalize) the optional `operator` key of a JSON row.
    ///
    /// Only condition rows have a predicate to compare, so an `operator` on an action
    /// row is rejected rather than silently dropped by the socket. Spelling is checked
    /// here too: leaving it to the socket would let `--condition-json {"operator":"ltt"}`
    /// fail only after a round-trip, and with the app down it would surface as a
    /// connection error instead of a bad argument.
    private static func validateOperator(in row: inout [String: String], flag: String) throws {
        guard let rawOperator = row["operator"] else { return }
        guard !flag.contains("action") else {
            throw ValidationError(
                "Invalid \(flag): 'operator' applies to conditions only; an action has no comparison.")
        }
        let trimmed = rawOperator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = normalizedComparisonOperator(trimmed) else {
            throw ValidationError(
                "Unknown \(flag) operator '\(trimmed)'. Allowed: "
                    + comparisonOperators.joined(separator: ", ") + " (or eq, ne, lt, lte, gt, gte).")
        }
        // An explicit operator plus a symbolic prefix on the value is contradictory.
        // The app rejects it too; catching it here fails before the socket round-trip.
        if let value = row["value"], let split = splitComparisonPrefix(value) {
            throw ValidationError(
                "Invalid \(flag): operator '\(normalized)' was given but value '\(value)' "
                    + "also starts with '\(split.op)'. Pass the bare value (for example '\(split.value)').")
        }
        row["operator"] = normalized
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