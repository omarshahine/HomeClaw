import CryptoKit
import Foundation

/// In-memory + JSON-persisted cache for HomeKit characteristic values.
/// Dramatically reduces response times for bulk operations (list, search, rooms)
/// by avoiding per-device `readValue()` network round-trips.
///
/// Follows the `HelperConfig` singleton pattern. All access is expected via `@MainActor`.
final class CharacteristicCache: @unchecked Sendable {
    static let shared = CharacteristicCache()

    private static let ttlSeconds: TimeInterval = 300 // 5 minutes (safety net; HMAccessoryDelegate handles real-time updates)

    private let configDir: URL
    private let cacheFile: URL
    private var data: CacheData

    struct CacheData: Codable {
        /// accessoryID -> {characteristicName: formattedValue}
        var values: [String: [String: String]] = [:]
        /// SHA256 of sorted accessory UUIDs — stable across restarts
        var deviceHash: String?
        /// When the cache was last fully warmed
        var lastWarmed: Date?

        enum CodingKeys: String, CodingKey {
            case values, deviceHash, lastWarmed
        }
    }

    private init() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        configDir = home.appendingPathComponent(".config/homeclaw")
        cacheFile = configDir.appendingPathComponent("cache.json")

        if let fileData = try? Data(contentsOf: cacheFile),
           let decoded = try? JSONDecoder.iso8601.decode(CacheData.self, from: fileData)
        {
            data = decoded
        } else {
            data = CacheData()
        }
    }

    // MARK: - Read

    /// Returns cached characteristic state for an accessory, or nil if not cached.
    func cachedState(for accessoryID: String) -> [String: String]? {
        data.values[accessoryID]
    }

    /// True if the cache has never been warmed or is older than TTL.
    var isStale: Bool {
        guard let lastWarmed = data.lastWarmed else { return true }
        return Date().timeIntervalSince(lastWarmed) > Self.ttlSeconds
    }

    /// True if no characteristic values are cached.
    var isEmpty: Bool {
        data.values.isEmpty
    }

    /// Number of accessories with cached values.
    var cachedAccessoryCount: Int {
        data.values.count
    }

    /// When the cache was last warmed, as ISO 8601 string.
    var lastWarmedString: String? {
        data.lastWarmed.map { ISO8601DateFormatter().string(from: $0) }
    }

    /// True if the given device hash matches the stored one.
    func deviceHashMatches(_ hash: String) -> Bool {
        data.deviceHash == hash
    }

    // MARK: - Write

    /// Update cached values for a single accessory.
    func setValues(for accessoryID: String, state: [String: String]) {
        data.values[accessoryID] = state
    }

    /// Mark the cache as freshly warmed with the given device hash.
    func markWarmed(deviceHash: String) {
        data.deviceHash = deviceHash
        data.lastWarmed = Date()
        save()
    }

    /// Clear all cached values (e.g., when device set changes).
    func invalidateValues() {
        data.values.removeAll()
        data.deviceHash = nil
        data.lastWarmed = nil
        save()
    }

    /// Persist current cache to disk.
    func save() {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let encoded = try JSONEncoder.iso8601.encode(data)
            try encoded.write(to: cacheFile, options: .atomic)
        } catch {
            HelperLogger.homekit.error("Failed to save cache: \(error.localizedDescription)")
        }
    }

    // MARK: - Device Hash

    /// Computes a stable SHA256 hash from sorted accessory UUIDs.
    static func computeDeviceHash(accessoryIDs: [String]) -> String {
        let sorted = accessoryIDs.sorted()
        let joined = sorted.joined(separator: ",")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - JSON Encoder/Decoder with ISO 8601 Date Support

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
