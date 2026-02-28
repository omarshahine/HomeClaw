import Foundation

/// Persistent configuration for the HomeKit helper.
/// Stored as JSON at ~/Library/Application Support/HomeClaw/config.json.
/// This path is sandbox-safe (accessible without special entitlements).
///
/// Migration: If the legacy path (~/.config/homeclaw/config.json) exists
/// and the new path does not, config is automatically migrated on first launch.
final class HomeClawConfig: @unchecked Sendable {
    static let shared = HomeClawConfig()

    private let configDir: URL
    private let configFile: URL
    private var config: ConfigData

    struct WebhookConfig: Codable, Sendable {
        var enabled: Bool
        var url: String
        var token: String
        var events: [String]?  // nil = all events; or subset of event type strings
    }

    /// A webhook trigger rule. When an event matches the conditions, a webhook is fired.
    ///
    /// Match types:
    /// - `accessory`: matches a specific accessory by UUID
    /// - `scene`: matches when a specific scene is triggered (by name or UUID)
    /// - `characteristic`: matches any accessory with a characteristic reaching a value
    ///
    /// When `characteristic` and `value` are set alongside `accessoryID`,
    /// both conditions must match (AND logic).
    struct WebhookTrigger: Codable, Sendable, Identifiable {
        var id: String                 // Unique trigger ID (UUID string)
        var label: String              // Human-readable label, e.g. "Front door unlocked"
        var enabled: Bool

        // Match conditions (at least one of these must be set)
        var accessoryID: String?       // Match specific accessory UUID
        var accessoryType: String?     // Match semantic type: lighting, door_lock, etc.
        var sceneName: String?         // Match scene trigger by name
        var sceneID: String?           // Match scene trigger by UUID
        var characteristic: String?    // Match characteristic name, e.g. "lock_target_state"
        var value: String?             // Match characteristic value, e.g. "unlocked"

        // Optional custom webhook message (falls back to auto-generated)
        var message: String?

        /// Creates a new trigger with a generated ID.
        static func create(label: String) -> WebhookTrigger {
            WebhookTrigger(id: UUID().uuidString, label: label, enabled: true)
        }
    }

    struct EventLogConfig: Codable, Sendable {
        var enabled: Bool?           // nil = true (default on)
        var maxSizeMB: Int?          // nil = 50 MB default
        var maxBackups: Int?         // nil = 3 backups default

        static let defaultMaxSizeMB = 50
        static let defaultMaxBackups = 3
    }

    struct ConfigData: Codable {
        var defaultHomeID: String?
        var accessoryFilterMode: String?    // "all" (default) or "allowlist"
        var allowedAccessoryIDs: [String]?  // UUIDs of allowed accessories
        var temperatureUnit: String?        // "F" or "C" (nil = auto-detect from locale)
        var webhook: WebhookConfig?
        var eventLog: EventLogConfig?
        var webhookTriggers: [WebhookTrigger]?
    }

    /// Sandbox-safe config directory under Application Support.
    static var configDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("HomeClaw")
    }

    private init() {
        configDir = Self.configDirectory
        configFile = configDir.appendingPathComponent("config.json")

        // Migrate from legacy path if needed
        Self.migrateIfNeeded(to: configDir)

        // Load existing config or start with defaults
        if let data = try? Data(contentsOf: configFile),
           let decoded = try? JSONDecoder().decode(ConfigData.self, from: data)
        {
            config = decoded
        } else {
            config = ConfigData()
        }
    }

    var defaultHomeID: String? {
        get { config.defaultHomeID }
        set {
            config.defaultHomeID = newValue
            save()
        }
    }

    var filterMode: String {
        get { config.accessoryFilterMode ?? "all" }
        set {
            config.accessoryFilterMode = newValue
            save()
        }
    }

    var allowedIDs: Set<String>? {
        guard let ids = config.allowedAccessoryIDs, !ids.isEmpty else { return nil }
        return Set(ids)
    }

    func setAllowedAccessories(_ ids: [String]) {
        config.allowedAccessoryIDs = ids.isEmpty ? nil : ids
        save()
    }

    /// Temperature display unit: "F" or "C".
    /// Auto-detected from system locale when not explicitly set.
    var temperatureUnit: String {
        get {
            if let explicit = config.temperatureUnit {
                return explicit
            }
            // Auto-detect: US, Liberia, and Myanmar use Fahrenheit
            return Locale.current.measurementSystem == .us ? "F" : "C"
        }
        set {
            let unit = newValue.uppercased()
            config.temperatureUnit = (unit == "F" || unit == "C") ? unit : nil
            save()
        }
    }

    /// Whether temperatures should display in Fahrenheit.
    var useFahrenheit: Bool { temperatureUnit == "F" }

    /// Webhook configuration for pushing events to OpenClaw or other services.
    var webhookConfig: WebhookConfig? {
        get { config.webhook }
        set {
            config.webhook = newValue
            save()
        }
    }

    /// Event log configuration (size limits, backup count).
    var eventLogConfig: EventLogConfig {
        get { config.eventLog ?? EventLogConfig() }
        set {
            config.eventLog = newValue
            save()
        }
    }

    /// Whether event logging is enabled.
    var eventLogEnabled: Bool {
        get { eventLogConfig.enabled ?? true }
        set {
            var cfg = eventLogConfig
            cfg.enabled = newValue
            eventLogConfig = cfg
        }
    }

    /// Maximum event log file size in megabytes.
    var eventLogMaxSizeMB: Int {
        get { eventLogConfig.maxSizeMB ?? EventLogConfig.defaultMaxSizeMB }
        set {
            var cfg = eventLogConfig
            cfg.maxSizeMB = max(1, newValue)
            eventLogConfig = cfg
        }
    }

    /// Number of rotated backup files to keep.
    var eventLogMaxBackups: Int {
        get { eventLogConfig.maxBackups ?? EventLogConfig.defaultMaxBackups }
        set {
            var cfg = eventLogConfig
            cfg.maxBackups = max(0, min(10, newValue))
            eventLogConfig = cfg
        }
    }

    /// Webhook triggers — rules that fire webhooks on matching events.
    var webhookTriggers: [WebhookTrigger] {
        get { config.webhookTriggers ?? [] }
        set {
            config.webhookTriggers = newValue.isEmpty ? nil : newValue
            save()
        }
    }

    func addWebhookTrigger(_ trigger: WebhookTrigger) {
        var triggers = webhookTriggers
        triggers.append(trigger)
        webhookTriggers = triggers
    }

    func removeWebhookTrigger(id: String) {
        webhookTriggers = webhookTriggers.filter { $0.id != id }
    }

    func updateWebhookTrigger(_ trigger: WebhookTrigger) {
        var triggers = webhookTriggers
        if let idx = triggers.firstIndex(where: { $0.id == trigger.id }) {
            triggers[idx] = trigger
            webhookTriggers = triggers
        }
    }

    /// Converts Celsius to the configured display unit and formats with unit suffix.
    func formatTemperature(_ celsius: Double) -> String {
        if useFahrenheit {
            let fahrenheit = celsius * 9.0 / 5.0 + 32.0
            return String(format: "%.0f°F", fahrenheit)
        } else {
            return String(format: "%.1f°C", celsius)
        }
    }

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [:]
        if let id = config.defaultHomeID {
            dict["default_home_id"] = id
        }
        dict["accessory_filter_mode"] = filterMode
        if let ids = config.allowedAccessoryIDs, !ids.isEmpty {
            dict["allowed_accessory_ids"] = ids
        }
        dict["temperature_unit"] = temperatureUnit
        if let webhook = config.webhook {
            var whDict: [String: Any] = [
                "enabled": webhook.enabled,
                "url": webhook.url,
            ]
            if let events = webhook.events, !events.isEmpty {
                whDict["events"] = events
            }
            dict["webhook"] = whDict
        }
        dict["event_log"] = [
            "enabled": eventLogEnabled,
            "max_size_mb": eventLogMaxSizeMB,
            "max_backups": eventLogMaxBackups,
        ] as [String: Any]
        return dict
    }

    /// Migrates config from legacy ~/.config/homeclaw/ to new Application Support path.
    private static func migrateIfNeeded(to newDir: URL) {
        let fm = FileManager.default
        let legacyDir = URL(fileURLWithPath: AppConfig.realHomeDirectory).appendingPathComponent(".config/homeclaw")
        let legacyConfig = legacyDir.appendingPathComponent("config.json")
        let newConfig = newDir.appendingPathComponent("config.json")

        guard fm.fileExists(atPath: legacyConfig.path),
              !fm.fileExists(atPath: newConfig.path)
        else { return }

        do {
            try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
            try fm.copyItem(at: legacyConfig, to: newConfig)

            // Also migrate cache.json if it exists
            let legacyCache = legacyDir.appendingPathComponent("cache.json")
            let newCache = newDir.appendingPathComponent("cache.json")
            if fm.fileExists(atPath: legacyCache.path), !fm.fileExists(atPath: newCache.path) {
                try fm.copyItem(at: legacyCache, to: newCache)
            }
        } catch {
            // Migration is best-effort; new defaults will be created
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(config)
            try data.write(to: configFile, options: .atomic)
        } catch {
            // Log but don't crash
        }
    }
}
