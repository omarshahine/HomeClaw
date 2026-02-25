import HomeKit

/// Maps HomeKit characteristic type UUIDs to human-readable names and provides
/// value formatting for common characteristic types.
enum CharacteristicMapper {
    // MARK: - Characteristic Type Names

    private static let typeNames: [String: String] = [
        HMCharacteristicTypePowerState: "power",
        HMCharacteristicTypeBrightness: "brightness",
        HMCharacteristicTypeHue: "hue",
        HMCharacteristicTypeSaturation: "saturation",
        HMCharacteristicTypeCurrentTemperature: "current_temperature",
        HMCharacteristicTypeTargetTemperature: "target_temperature",
        HMCharacteristicTypeCurrentHeatingCooling: "current_heating_cooling",
        HMCharacteristicTypeTargetHeatingCooling: "target_heating_cooling",
        HMCharacteristicTypeTemperatureUnits: "temperature_units",
        HMCharacteristicTypeCurrentRelativeHumidity: "current_humidity",
        HMCharacteristicTypeTargetRelativeHumidity: "target_humidity",
        HMCharacteristicTypeCurrentLockMechanismState: "lock_current_state",
        HMCharacteristicTypeTargetLockMechanismState: "lock_target_state",
        HMCharacteristicTypeCurrentDoorState: "current_door_state",
        HMCharacteristicTypeTargetDoorState: "target_door_state",
        HMCharacteristicTypeObstructionDetected: "obstruction_detected",
        HMCharacteristicTypeMotionDetected: "motion_detected",
        HMCharacteristicTypeContactState: "contact_state",
        HMCharacteristicTypeCurrentLightLevel: "current_light_level",
        HMCharacteristicTypeBatteryLevel: "battery_level",
        HMCharacteristicTypeChargingState: "charging_state",
        HMCharacteristicTypeStatusLowBattery: "low_battery",
        HMCharacteristicTypeColorTemperature: "color_temperature",
        HMCharacteristicTypeCurrentPosition: "current_position",
        HMCharacteristicTypeTargetPosition: "target_position",
        HMCharacteristicTypePositionState: "position_state",
        HMCharacteristicTypeName: "name",
        HMCharacteristicTypeIdentify: "identify",
        HMCharacteristicTypeOutletInUse: "outlet_in_use",
        HMCharacteristicTypeCurrentFanState: "current_fan_state",
        HMCharacteristicTypeTargetFanState: "target_fan_state",
        HMCharacteristicTypeRotationDirection: "rotation_direction",
        HMCharacteristicTypeRotationSpeed: "rotation_speed",
        HMCharacteristicTypeSwingMode: "swing_mode",
        HMCharacteristicTypeActive: "active",
        HMCharacteristicTypeCurrentAirPurifierState: "air_purifier_state",
        HMCharacteristicTypeTargetAirPurifierState: "target_air_purifier_state",
        HMCharacteristicTypeAirQuality: "air_quality",
        HMCharacteristicTypeSmokeDetected: "smoke_detected",
        HMCharacteristicTypeCarbonMonoxideDetected: "carbon_monoxide_detected",
        HMCharacteristicTypeCarbonDioxideDetected: "carbon_dioxide_detected",
        HMCharacteristicTypeStatusActive: "status_active",
        HMCharacteristicTypeStatusFault: "status_fault",
        HMCharacteristicTypeStatusTampered: "status_tampered",
        HMCharacteristicTypeInputEvent: "input_event",
        HMCharacteristicTypeVolume: "volume",
        HMCharacteristicTypeMute: "mute",
        HMCharacteristicTypeLockPhysicalControls: "lock_physical_controls",
    ]

    /// Returns a human-readable name for a characteristic type UUID.
    static func name(for characteristicType: String) -> String {
        typeNames[characteristicType] ?? characteristicType
    }

    // MARK: - Writable Characteristics

    /// Characteristic types that can be written to (controlled).
    static let writableTypes: Set<String> = [
        HMCharacteristicTypePowerState,
        HMCharacteristicTypeBrightness,
        HMCharacteristicTypeHue,
        HMCharacteristicTypeSaturation,
        HMCharacteristicTypeTargetTemperature,
        HMCharacteristicTypeTargetHeatingCooling,
        HMCharacteristicTypeTargetLockMechanismState,
        HMCharacteristicTypeTargetDoorState,
        HMCharacteristicTypeTargetPosition,
        HMCharacteristicTypeColorTemperature,
        HMCharacteristicTypeTargetFanState,
        HMCharacteristicTypeRotationSpeed,
        HMCharacteristicTypeRotationDirection,
        HMCharacteristicTypeSwingMode,
        HMCharacteristicTypeActive,
        HMCharacteristicTypeTargetAirPurifierState,
        HMCharacteristicTypeTargetRelativeHumidity,
        HMCharacteristicTypeVolume,
        HMCharacteristicTypeMute,
        HMCharacteristicTypeIdentify,
    ]

    /// Returns true if the characteristic type is writable.
    static func isWritable(_ characteristicType: String) -> Bool {
        writableTypes.contains(characteristicType)
    }

    // MARK: - Category Names

    /// Returns a human-readable category name for an accessory category type.
    static func categoryName(for categoryType: String) -> String {
        switch categoryType {
        case HMAccessoryCategoryTypeLightbulb: return "lightbulb"
        case HMAccessoryCategoryTypeSwitch: return "switch"
        case HMAccessoryCategoryTypeThermostat: return "thermostat"
        case HMAccessoryCategoryTypeDoorLock: return "lock"
        case HMAccessoryCategoryTypeGarageDoorOpener: return "garage_door"
        case HMAccessoryCategoryTypeDoor: return "door"
        case HMAccessoryCategoryTypeFan: return "fan"
        case HMAccessoryCategoryTypeOutlet: return "outlet"
        case HMAccessoryCategoryTypeSensor: return "sensor"
        case HMAccessoryCategoryTypeSecuritySystem: return "security_system"
        case HMAccessoryCategoryTypeProgrammableSwitch: return "programmable_switch"
        case HMAccessoryCategoryTypeWindow: return "window"
        case HMAccessoryCategoryTypeWindowCovering: return "window_covering"
        case HMAccessoryCategoryTypeAirPurifier: return "air_purifier"
        case HMAccessoryCategoryTypeBridge: return "bridge"
        case HMAccessoryCategoryTypeIPCamera: return "camera"
        case HMAccessoryCategoryTypeVideoDoorbell: return "doorbell"
        case HMAccessoryCategoryTypeRangeExtender: return "range_extender"
        default: return "other"
        }
    }

    // MARK: - Service-Based Category Inference

    /// Maps every `HMServiceType*` constant from the HomeKit SDK to a category name.
    /// Built exhaustively from the SDK headers — gaps are visible by comparing against
    /// `HMServiceTypes.h`. Services that don't imply a device category (metadata,
    /// supplementary) are omitted intentionally and listed in the comment below.
    ///
    /// Omitted (supplementary/metadata services, not device categories):
    ///   AccessoryInformation, Battery, FilterMaintenance, InputSource, Label,
    ///   LockManagement
    private static let serviceCategoryMap: [String: String] = [
        // Lighting
        HMServiceTypeLightbulb: "lightbulb",

        // Climate
        HMServiceTypeThermostat: "thermostat",
        HMServiceTypeHeaterCooler: "thermostat",
        HMServiceTypeFan: "fan",
        HMServiceTypeVentilationFan: "fan",
        HMServiceTypeAirPurifier: "air_purifier",
        HMServiceTypeHumidifierDehumidifier: "air_purifier",

        // Locks & doors
        HMServiceTypeLockMechanism: "lock",
        HMServiceTypeGarageDoorOpener: "garage_door",
        HMServiceTypeDoorbell: "doorbell",
        HMServiceTypeDoor: "door",

        // Window coverings
        HMServiceTypeWindowCovering: "window_covering",
        HMServiceTypeWindow: "window",
        HMServiceTypeSlats: "window_covering",

        // Power
        HMServiceTypeOutlet: "outlet",
        HMServiceTypeSwitch: "switch",
        HMServiceTypeStatelessProgrammableSwitch: "programmable_switch",
        HMServiceTypeStatefulProgrammableSwitch: "programmable_switch",

        // Security & cameras
        HMServiceTypeSecuritySystem: "security_system",
        HMServiceTypeCameraControl: "camera",
        HMServiceTypeCameraRTPStreamManagement: "camera",
        // HKSV (HomeKit Secure Video) services — no HMServiceType constants exist for these
        "0000021A-0000-1000-8000-0026BB765291": "camera",  // Camera Operating Mode
        "00000204-0000-1000-8000-0026BB765291": "camera",  // Camera Recording Management

        // Water
        HMServiceTypeIrrigationSystem: "irrigation",
        HMServiceTypeValve: "valve",
        HMServiceTypeFaucet: "faucet",

        // Media
        HMServiceTypeTelevision: "television",
        HMServiceTypeSpeaker: "speaker",
        HMServiceTypeMicrophone: "speaker",

        // Network
        HMServiceTypeWiFiRouter: "network",
        HMServiceTypeWiFiSatellite: "network",

        // Sensors (all map to "sensor")
        HMServiceTypeMotionSensor: "sensor",
        HMServiceTypeContactSensor: "sensor",
        HMServiceTypeTemperatureSensor: "sensor",
        HMServiceTypeHumiditySensor: "sensor",
        HMServiceTypeLeakSensor: "sensor",
        HMServiceTypeSmokeSensor: "sensor",
        HMServiceTypeCarbonMonoxideSensor: "sensor",
        HMServiceTypeCarbonDioxideSensor: "sensor",
        HMServiceTypeLightSensor: "sensor",
        HMServiceTypeOccupancySensor: "sensor",
        HMServiceTypeAirQualitySensor: "sensor",
    ]

    /// Priority order for category resolution when multiple services are present.
    /// More specific device types are checked first (e.g., a thermostat with a
    /// temperature sensor should be classified as "thermostat", not "sensor").
    private static let categoryPriority: [String] = [
        "lightbulb", "thermostat", "lock", "garage_door", "doorbell",
        "door", "window_covering", "window", "outlet", "fan",
        "air_purifier", "security_system", "television", "irrigation",
        "valve", "faucet", "camera", "speaker", "network",
        "switch", "programmable_switch", "sensor",
    ]

    /// Returns the best category name for an accessory, falling back to service-based
    /// inference when the manufacturer-provided category is generic ("other").
    ///
    /// Many accessories (especially bridged ones from Aqara, SmartThings, Lutron, etc.)
    /// report a generic category type even though their services correctly describe
    /// their capabilities. This method checks the accessory's services as a fallback.
    static func inferredCategoryName(for accessory: HMAccessory) -> String {
        let category = categoryName(for: accessory.category.categoryType)
        if category != "other" {
            return category
        }

        // Collect candidate categories from all services
        var candidates = Set<String>()
        for service in accessory.services {
            if let cat = serviceCategoryMap[service.serviceType] {
                candidates.insert(cat)
            }
        }

        // Return the highest-priority match
        for cat in categoryPriority {
            if candidates.contains(cat) {
                return cat
            }
        }

        return "other"
    }

    // MARK: - Value Formatting

    /// Formats a characteristic value for display, handling enums like door/lock states.
    /// Temperature values are converted to the configured unit (F/C) via HelperConfig.
    static func formatValue(_ value: Any?, for characteristicType: String) -> String {
        guard let value else { return "nil" }

        switch characteristicType {
        case HMCharacteristicTypeCurrentTemperature,
             HMCharacteristicTypeTargetTemperature:
            if let num = value as? Double {
                return HelperConfig.shared.formatTemperature(num)
            } else if let num = value as? NSNumber {
                return HelperConfig.shared.formatTemperature(num.doubleValue)
            }

        case HMCharacteristicTypeCurrentLockMechanismState,
             HMCharacteristicTypeTargetLockMechanismState:
            if let intVal = value as? Int {
                switch intVal {
                case HMCharacteristicValueLockMechanismState.unsecured.rawValue: return "unlocked"
                case HMCharacteristicValueLockMechanismState.secured.rawValue: return "locked"
                case HMCharacteristicValueLockMechanismState.jammed.rawValue: return "jammed"
                case HMCharacteristicValueLockMechanismState.unknown.rawValue: return "unknown"
                default: return "\(intVal)"
                }
            }

        case HMCharacteristicTypeCurrentDoorState,
             HMCharacteristicTypeTargetDoorState:
            if let intVal = value as? Int {
                switch intVal {
                case HMCharacteristicValueDoorState.open.rawValue: return "open"
                case HMCharacteristicValueDoorState.closed.rawValue: return "closed"
                case HMCharacteristicValueDoorState.opening.rawValue: return "opening"
                case HMCharacteristicValueDoorState.closing.rawValue: return "closing"
                case HMCharacteristicValueDoorState.stopped.rawValue: return "stopped"
                default: return "\(intVal)"
                }
            }

        case HMCharacteristicTypeCurrentHeatingCooling,
             HMCharacteristicTypeTargetHeatingCooling:
            if let intVal = value as? Int {
                switch intVal {
                case HMCharacteristicValueHeatingCooling.off.rawValue: return "off"
                case HMCharacteristicValueHeatingCooling.heat.rawValue: return "heat"
                case HMCharacteristicValueHeatingCooling.cool.rawValue: return "cool"
                case HMCharacteristicValueHeatingCooling.auto.rawValue: return "auto"
                default: return "\(intVal)"
                }
            }

        case HMCharacteristicTypePowerState,
             HMCharacteristicTypeObstructionDetected,
             HMCharacteristicTypeMotionDetected,
             HMCharacteristicTypeStatusActive,
             HMCharacteristicTypeOutletInUse,
             HMCharacteristicTypeMute:
            if let boolVal = value as? Bool {
                return boolVal ? "true" : "false"
            }

        default:
            break
        }

        return "\(value)"
    }

    /// Parses a string value into the appropriate type for writing to a characteristic.
    static func parseValue(_ stringValue: String, for characteristic: HMCharacteristic) -> Any? {
        let metadata = characteristic.metadata

        // Boolean types
        if metadata?.format == HMCharacteristicMetadataFormatBool {
            switch stringValue.lowercased() {
            case "true", "on", "1", "yes": return true
            case "false", "off", "0", "no": return false
            default: return nil
            }
        }

        // Integer types
        if metadata?.format == HMCharacteristicMetadataFormatInt
            || metadata?.format == HMCharacteristicMetadataFormatUInt8
            || metadata?.format == HMCharacteristicMetadataFormatUInt16
            || metadata?.format == HMCharacteristicMetadataFormatUInt32
            || metadata?.format == HMCharacteristicMetadataFormatUInt64
        {
            // Handle named values
            switch stringValue.lowercased() {
            case "locked", "secured":
                return HMCharacteristicValueTargetLockMechanismState.secured.rawValue
            case "unlocked", "unsecured":
                return HMCharacteristicValueTargetLockMechanismState.unsecured.rawValue
            case "open": return HMCharacteristicValueDoorState.open.rawValue
            case "closed": return HMCharacteristicValueDoorState.closed.rawValue
            case "off": return 0
            case "heat": return 1
            case "cool": return 2
            case "auto": return 3
            default: return Int(stringValue)
            }
        }

        // Float types
        if metadata?.format == HMCharacteristicMetadataFormatFloat {
            return Float(stringValue)
        }

        return stringValue
    }
}
