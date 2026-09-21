import Foundation

/// Consumer-side check of the producer's get_accessory freshness contract.
///
/// Mirrors `lib/freshness.js` `validateFreshAccessoryPayload`, which guards the
/// stdio MCP path, so the native HTTP transport rejects the same payloads with
/// the same messages. Returns nil when the payload is acceptable, otherwise the
/// violation message.
enum AccessoryFreshnessContract {
    static func violation(in payload: [String: Any], allowStale: Bool) -> String? {
        func fail(_ message: String) -> String { "HomeClaw freshness contract violation: \(message)" }

        guard let attempted = payload["read_attempted"] as? Int,
              let succeeded = payload["read_succeeded"] as? Int
        else { return fail("read counts are missing or malformed") }
        let refreshed = payload["refreshed"] as? Bool

        if allowStale {
            return refreshed == false && attempted == 0 && succeeded == 0
                ? nil
                : fail("invalid no-refresh response")
        }

        guard refreshed == true, attempted > 0, succeeded == attempted else {
            let reason = payload["reachable"] as? Bool == false
                ? "accessory is not reachable"
                : "\(succeeded) of \(attempted) characteristic reads succeeded"
            return fail("live refresh failed (\(reason)); values may be last-known. Pass no_refresh: true to read last-known values")
        }
        guard let services = payload["services"] as? [Any] else { return fail("services are missing") }

        let reads: [Any] = services.flatMap { service -> [Any] in
            guard let characteristics = (service as? [String: Any])?["characteristics"] as? [Any] else { return [] }
            return characteristics.compactMap { characteristic -> Any? in
                guard let characteristic = characteristic as? [String: Any], characteristic.keys.contains("read") else { return nil }
                return characteristic["read"] ?? NSNull()
            }
        }
        guard reads.count == attempted else { return fail("characteristic read count is inconsistent") }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        for read in reads {
            guard let read = read as? [String: Any],
                  read["succeeded"] as? Bool == true,
                  let observedAt = read["observed_at"] as? String,
                  formatter.date(from: observedAt) != nil || plainFormatter.date(from: observedAt) != nil
            else { return fail("characteristic attestation is invalid") }
        }
        return nil
    }
}
