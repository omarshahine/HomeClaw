import Foundation

/// Persistent configuration for the HomeKit helper.
/// Stored as JSON at ~/.config/homeclaw/config.json.
final class HelperConfig: @unchecked Sendable {
    static let shared = HelperConfig()

    private let configDir: URL
    private let configFile: URL
    private var config: ConfigData

    struct ConfigData: Codable {
        var defaultHomeID: String?
        var accessoryFilterMode: String?    // "all" (default) or "allowlist"
        var allowedAccessoryIDs: [String]?  // UUIDs of allowed accessories
        var temperatureUnit: String?        // "F" or "C" (nil = auto-detect from locale)
    }

    private init() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        configDir = home.appendingPathComponent(".config/homeclaw")
        configFile = configDir.appendingPathComponent("config.json")

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
        return dict
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
