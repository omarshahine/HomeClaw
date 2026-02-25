import Foundation

/// Pretty-prints a value as JSON to stdout.
func printJSON(_ value: Any?) {
    guard let value else {
        print("null")
        return
    }

    // If it's already JSON-serializable
    if JSONSerialization.isValidJSONObject(value) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8)
        {
            print(string)
            return
        }
    }

    // Fallback
    print("\(value)")
}
