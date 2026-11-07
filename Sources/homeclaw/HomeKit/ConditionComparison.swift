import Foundation

/// Comparison operator for a characteristic automation condition.
///
/// HomeKit has always supported ordered comparisons here — the trigger predicate
/// factory `HMEventTrigger.predicateForEvaluatingTrigger(_:relatedBy:toValue:)`
/// accepts every `NSComparisonPredicate.Operator` except the string-matching ones —
/// but HomeClaw only ever wrote `.equalTo`, so a numeric gate such as "only when the
/// room is darker than 30 lux" could not be expressed at all. This type is the
/// single vocabulary shared by the CLI rows, the socket args, the app's MCP handlers
/// and the predicate builder.
///
/// The canonical spelling matches what the read side reports for a decoded
/// characteristic condition (`operator: "<"`), so a condition read back from
/// `automations get` round-trips into a create/edit unchanged.
enum ConditionComparison: String, CaseIterable, Sendable {
    case equal = "=="
    case notEqual = "!="
    case lessThan = "<"
    case lessThanOrEqual = "<="
    case greaterThan = ">"
    case greaterThanOrEqual = ">="

    /// Canonical API spelling, identical to the `operator` field `automations get`
    /// reports for a decoded characteristic condition.
    var apiValue: String { rawValue }

    /// Human-readable form for CLI output, e.g. `current_light_level < 30`.
    var displaySymbol: String { rawValue }

    /// True for the four ordered comparisons, which need a numeric operand. HomeKit
    /// will accept `power < true` as a predicate and the resulting automation simply
    /// never fires, so this is checked before anything is written.
    var requiresNumericOperand: Bool {
        switch self {
        case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual: return true
        case .equal, .notEqual: return false
        }
    }

    var nsOperator: NSComparisonPredicate.Operator {
        switch self {
        case .equal: return .equalTo
        case .notEqual: return .notEqualTo
        case .lessThan: return .lessThan
        case .lessThanOrEqual: return .lessThanOrEqualTo
        case .greaterThan: return .greaterThan
        case .greaterThanOrEqual: return .greaterThanOrEqualTo
        }
    }

    /// Parse an operator from either the symbolic form (`<`, `<=`, `==`, …) or the
    /// short mnemonic (`lt`, `lte`, `gt`, `gte`, `eq`, `ne`). Case-insensitive;
    /// surrounding whitespace and newlines are ignored.
    ///
    /// Returns nil for anything else so every caller can fail loud. Falling back to
    /// equality would turn a typo (`--operator ltt`) into a silently different rule
    /// that still fires, which is the failure mode this whole path exists to avoid.
    static func parse(_ raw: String) -> ConditionComparison? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = ConditionComparison(rawValue: trimmed) { return exact }
        switch trimmed {
        case "eq", "equals", "equalto": return .equal
        case "ne", "neq", "notequalto": return .notEqual
        case "lt", "lessthan": return .lessThan
        case "lte", "le", "lessthanorequalto": return .lessThanOrEqual
        case "gt", "greaterthan": return .greaterThan
        case "gte", "ge", "greaterthanorequalto": return .greaterThanOrEqual
        default: return nil
        }
    }

    /// True when the text is a plain decimal number: optional sign, digits, at most one dot.
    ///
    /// `Double(String)` is too permissive for this decision — it also accepts `nan`, `inf`,
    /// `infinity` and hex floats such as `0x1p3`, so `"<inf"` on a string characteristic would
    /// still be peeled into a comparison. Only ordinary decimal text counts as a threshold.
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

    /// Split a leading comparison off a value string: `"<30"` → (`.lessThan`, `"30"`).
    ///
    /// Longest prefix wins, so `"<=30"` never parses as `<` followed by `"=30"`.
    ///
    /// A prefix is only peeled when what follows is a number or an on/off token, because the
    /// prefix exists for numeric thresholds. A string characteristic can legitimately hold a
    /// value that starts with a comparison character (`"<none>"`, `"!=x"`); splitting those
    /// would silently rewrite an existing equality condition into a comparison, and naming `==`
    /// explicitly would then be rejected as a conflict, leaving the value inexpressible.
    /// A boolean token is the exception: `"<on"` is a mistaken threshold, so it peels and the
    /// caller gets "on/off values only support == and !=" rather than a silent equality
    /// against the literal text.
    ///
    /// A bare operator with nothing after it still splits, with an empty remainder, so callers
    /// keep reporting "operator but no value" instead of treating `"<"` as a literal string.
    static func splitValuePrefix(_ raw: String) -> (comparison: ConditionComparison, value: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes: [(String, ConditionComparison)] = [
            ("==", .equal), ("!=", .notEqual),
            ("<=", .lessThanOrEqual), (">=", .greaterThanOrEqual),
            ("<", .lessThan), (">", .greaterThan),
        ]
        for (prefix, comparison) in prefixes where trimmed.hasPrefix(prefix) {
            let remainder = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty { return (comparison, remainder) }
            let numericPart = remainder.hasSuffix("%") ? String(remainder.dropLast()) : remainder
            // A boolean token after an operator is a mistaken threshold (`"<on"`), not a string
            // value: peel it so the caller gets "on/off values only support == and !=" instead of
            // a silent equality against the literal text. `"<none>"` is not a token and stays
            // literal, which is the case the numeric rule exists to protect.
            if Self.isDecimalThreshold(numericPart) || Self.isBooleanToken(remainder) {
                return (comparison, remainder)
            }
            return nil
        }
        return nil
    }

    /// Outcome of deciding the comparison and bare value for one condition row.
    enum Resolution: Equatable {
        case ok(comparison: ConditionComparison, value: String)
        /// An explicit operator and a symbolic prefix on the value contradict.
        case conflict(comparison: ConditionComparison, value: String)
        case unknownOperator(String)
    }

    /// Decide the comparison and bare value, with one precedence rule for every entry
    /// point (`create`, `edit`, `add-condition`, socket, app MCP).
    ///
    /// An operator the caller names always wins, and leaving a comparison prefix on the
    /// value at the same time is an error rather than a guess — `operator: "=="` with
    /// `value: "<30"` used to be silently written as `< 30`. Only when no operator is
    /// named does a prefix get peeled off the value.
    static func resolve(explicitOperator: String?, value: String) -> Resolution {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicitOperator {
            let trimmedOperator = explicitOperator.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let comparison = parse(trimmedOperator) else {
                return .unknownOperator(trimmedOperator)
            }
            if splitValuePrefix(trimmedValue) != nil {
                return .conflict(comparison: comparison, value: trimmedValue)
            }
            return .ok(comparison: comparison, value: trimmedValue)
        }
        if let split = splitValuePrefix(trimmedValue) {
            return .ok(comparison: split.comparison, value: split.value)
        }
        return .ok(comparison: .equal, value: trimmedValue)
    }

    /// Outcome of reading an optional `operator` wire argument.
    enum OperatorArg: Equatable {
        /// Absent or JSON `null`: no operator was named.
        case absent
        case comparison(ConditionComparison)
        /// Present but not a string (a number, a bool, an object, …).
        case notString
        /// A string that is empty after trimming.
        case empty
        case unknown(String)
    }

    /// Read an optional `operator` argument from a decoded JSON payload. Every entry
    /// point (socket rows, socket `add-condition`, the app's MCP handler) uses this so
    /// they agree with the Node handler: absent and `null` both mean "not provided";
    /// anything else must be a non-empty, known operator string. Each caller maps the
    /// failure cases to its own error type and wording.
    static func parseOperatorArg(_ raw: Any?) -> OperatorArg {
        guard let raw, !(raw is NSNull) else { return .absent }
        guard let string = raw as? String else { return .notString }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let comparison = parse(trimmed) else { return .unknown(trimmed) }
        return .comparison(comparison)
    }

    /// True when `value` is an explicit on/off token (`on`, `off`, `true`, `false`,
    /// case-insensitive). Such a token is never a valid operand for an ordered
    /// comparison, whatever the characteristic, so this needs no metadata and demo and
    /// live mode both reject it. "0"/"1" are deliberately NOT included: on a numeric
    /// characteristic they are ordinary thresholds, and only the characteristic's
    /// metadata (live mode) can tell the two readings apart.
    static func isBooleanToken(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on", "off", "true", "false": return true
        default: return false
        }
    }

    /// Error message when an ordered comparison is given an on/off token, or nil when
    /// the pair is acceptable as far as can be told without characteristic metadata.
    static func booleanTokenRejection(_ comparison: ConditionComparison, value: String, property: String) -> String? {
        guard comparison.requiresNumericOperand, isBooleanToken(value) else { return nil }
        let label = property.trimmingCharacters(in: .whitespaces)
        return "Operator '\(comparison.apiValue)' needs a numeric value, but the condition for "
            + "'\(label)' compares against '\(value.trimmingCharacters(in: .whitespacesAndNewlines))'. "
            + "On/off values only support == and !=; "
            + "use a numeric characteristic (for example current_light_level) for a threshold."
    }

    /// The allowed set, so error messages never restate a list that can drift from the
    /// enum itself.
    static var allowedOperatorsDescription: String {
        allCases.map(\.apiValue).joined(separator: ", ") + " (or eq, ne, lt, lte, gt, gte)"
    }
}