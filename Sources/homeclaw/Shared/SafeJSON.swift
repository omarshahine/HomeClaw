import Foundation

/// JSON encoding that never raises.
///
/// `JSONSerialization.data(withJSONObject:)` raises an Objective-C
/// `NSInvalidArgumentException` (which `try?` cannot catch) for a non-finite
/// number or a value that isn't a JSON type. Some accessories report a
/// characteristic value of infinity (issue #147). Raised on the main actor, the
/// exception unwinds out of the main queue's drain; AppKit swallows it, but the
/// main queue never drains again, so every later socket request hangs until the
/// app restarts.
enum SafeJSON {
    /// `value` with every non-finite number (NaN, ±infinity) replaced by `NSNull`,
    /// recursing into dictionaries and arrays.
    static func sanitized(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues(sanitized)
        case let array as [Any]:
            return array.map(sanitized)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number }
            return number.doubleValue.isFinite ? number : NSNull()
        default:
            return value
        }
    }

    /// Serializes `object`, writing non-finite numbers as `null`. Returns nil
    /// instead of raising when the result still isn't valid JSON.
    static func data(withJSONObject object: Any, options: JSONSerialization.WritingOptions = []) -> Data? {
        let clean = sanitized(object)
        guard JSONSerialization.isValidJSONObject(clean) else { return nil }
        return try? JSONSerialization.data(withJSONObject: clean, options: options)
    }
}
