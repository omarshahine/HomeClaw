import Foundation
import os

/// Logs HomeKit events to a JSONL file in Application Support.
/// Events are appended as newline-delimited JSON for efficient streaming reads.
/// Includes configurable log rotation and optional webhook delivery.
@MainActor
final class HomeEventLogger {
    static let shared = HomeEventLogger()

    private let eventsDir: URL
    private let eventsFile: URL
    private let fileManager = FileManager.default
    private let logger = AppLogger.homekit
    private static let isoFormatter = ISO8601DateFormatter()

    /// Webhook state
    private var webhookFailureCount = 0
    private var webhookCircuitOpen = false
    private var webhookCircuitOpenedAt: Date?
    private let webhookCircuitThreshold = 5
    private let webhookCircuitResetInterval: TimeInterval = 60

    /// Configurable max file size in bytes (read from config on each rotation check).
    private var maxFileSize: UInt64 {
        UInt64(HomeClawConfig.shared.eventLogMaxSizeMB) * 1_048_576
    }

    /// Configurable number of rotated backup files to keep.
    private var maxBackups: Int {
        HomeClawConfig.shared.eventLogMaxBackups
    }

    /// Whether event logging is enabled.
    private var isEnabled: Bool {
        HomeClawConfig.shared.eventLogEnabled
    }

    private init() {
        eventsDir = HomeClawConfig.configDirectory
        eventsFile = eventsDir.appendingPathComponent("events.jsonl")

        // Ensure directory exists
        try? fileManager.createDirectory(at: eventsDir, withIntermediateDirectories: true)
    }

    // MARK: - Event Types

    enum EventType: String {
        case characteristicChange = "characteristic_change"
        case homesUpdated = "homes_updated"
        case sceneTriggered = "scene_triggered"
        case accessoryControlled = "accessory_controlled"
    }

    // MARK: - Logging

    /// Logs a characteristic change event from the HMAccessoryDelegate callback.
    func logCharacteristicChange(
        accessoryID: String,
        accessoryName: String,
        room: String?,
        service: String,
        characteristic: String,
        value: String,
        previousValue: String?
    ) {
        var event: [String: Any] = [
            "timestamp": Self.isoFormatter.string(from: Date()),
            "type": EventType.characteristicChange.rawValue,
            "accessory": [
                "id": accessoryID,
                "name": accessoryName,
                "room": room as Any,
            ] as [String: Any],
            "service": service,
            "characteristic": characteristic,
            "value": value,
        ]
        if let previousValue {
            event["previous_value"] = previousValue
        }
        writeEvent(event)
    }

    /// Logs a homes updated event from the HMHomeManagerDelegate callback.
    func logHomesUpdated(homeCount: Int, accessoryCount: Int) {
        let event: [String: Any] = [
            "timestamp": Self.isoFormatter.string(from: Date()),
            "type": EventType.homesUpdated.rawValue,
            "homes": homeCount,
            "accessories": accessoryCount,
        ]
        writeEvent(event)
    }

    /// Logs a scene trigger event.
    func logSceneTriggered(sceneID: String, sceneName: String, homeName: String?) {
        var event: [String: Any] = [
            "timestamp": Self.isoFormatter.string(from: Date()),
            "type": EventType.sceneTriggered.rawValue,
            "scene": [
                "id": sceneID,
                "name": sceneName,
            ] as [String: Any],
        ]
        if let homeName {
            event["home"] = homeName
        }
        writeEvent(event)
    }

    /// Logs an accessory control event (user set a value via CLI/MCP).
    func logAccessoryControlled(
        accessoryID: String,
        accessoryName: String,
        characteristic: String,
        value: String
    ) {
        let event: [String: Any] = [
            "timestamp": Self.isoFormatter.string(from: Date()),
            "type": EventType.accessoryControlled.rawValue,
            "accessory": [
                "id": accessoryID,
                "name": accessoryName,
            ] as [String: Any],
            "characteristic": characteristic,
            "value": value,
        ]
        writeEvent(event)
    }

    // MARK: - Reading

    /// Reads events from the log file, with optional filtering.
    /// Returns events in reverse chronological order (newest first).
    func readEvents(
        since: Date? = nil,
        limit: Int = 100,
        type: EventType? = nil
    ) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: eventsFile),
              let content = String(data: data, encoding: .utf8)
        else { return [] }

        let formatter = ISO8601DateFormatter()
        var events: [[String: Any]] = []

        let lines = content.components(separatedBy: "\n").reversed()
        for line in lines {
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            // Filter by type
            if let type, event["type"] as? String != type.rawValue {
                continue
            }

            // Filter by timestamp
            if let since, let ts = event["timestamp"] as? String,
               let eventDate = formatter.date(from: ts), eventDate < since
            {
                break // Iterating newest-first; all remaining events are older, so stop
            }

            events.append(event)
            if events.count >= limit { break }
        }

        return events
    }

    // MARK: - Stats & Management

    /// Returns statistics about the event log files.
    func logStats() -> [String: Any] {
        var totalSize: UInt64 = 0
        var fileCount = 0

        // Main log file
        if let attrs = try? fileManager.attributesOfItem(atPath: eventsFile.path),
           let size = attrs[.size] as? UInt64
        {
            totalSize += size
            fileCount += 1
        }

        // Rotated backup files
        for i in 1...max(1, maxBackups) {
            let backup = eventsDir.appendingPathComponent("events.jsonl.\(i)")
            if let attrs = try? fileManager.attributesOfItem(atPath: backup.path),
               let size = attrs[.size] as? UInt64
            {
                totalSize += size
                fileCount += 1
            }
        }

        return [
            "enabled": isEnabled,
            "file_count": fileCount,
            "total_size_bytes": totalSize,
            "total_size_mb": String(format: "%.1f", Double(totalSize) / 1_048_576),
            "max_size_mb": HomeClawConfig.shared.eventLogMaxSizeMB,
            "max_backups": maxBackups,
            "path": eventsFile.path,
        ]
    }

    /// Deletes all event log files.
    func purge() {
        try? fileManager.removeItem(at: eventsFile)
        for i in 1...10 {
            let backup = eventsDir.appendingPathComponent("events.jsonl.\(i)")
            try? fileManager.removeItem(at: backup)
        }
        logger.info("Event log purged")
    }

    // MARK: - Private

    private func writeEvent(_ event: [String: Any]) {
        guard isEnabled else { return }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              var line = String(data: jsonData, encoding: .utf8)
        else { return }

        line += "\n"

        rotateIfNeeded()

        if let handle = try? FileHandle(forWritingTo: eventsFile) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            // File doesn't exist yet — create it
            try? line.data(using: .utf8)?.write(to: eventsFile, options: .atomic)
        }

        // Fire general webhook and check triggers
        deliverWebhook(event)
        evaluateTriggers(event)
    }

    private func rotateIfNeeded() {
        guard let attrs = try? fileManager.attributesOfItem(atPath: eventsFile.path),
              let size = attrs[.size] as? UInt64,
              size >= maxFileSize
        else { return }

        let backups = maxBackups

        // Shift existing backups: .N → .N+1, removing the oldest if over limit
        for i in stride(from: backups, through: 1, by: -1) {
            let src = eventsDir.appendingPathComponent("events.jsonl.\(i)")
            if i >= backups {
                try? fileManager.removeItem(at: src)
            } else {
                let dst = eventsDir.appendingPathComponent("events.jsonl.\(i + 1)")
                try? fileManager.removeItem(at: dst)
                try? fileManager.moveItem(at: src, to: dst)
            }
        }

        // Rotate current → .1
        if backups > 0 {
            let dst = eventsDir.appendingPathComponent("events.jsonl.1")
            try? fileManager.removeItem(at: dst)
            try? fileManager.moveItem(at: eventsFile, to: dst)
        } else {
            // No backups — just truncate
            try? fileManager.removeItem(at: eventsFile)
        }

        logger.info("Event log rotated (max \(self.maxFileSize / 1_048_576) MB, \(backups) backups)")
    }

    // MARK: - Triggers

    /// Evaluates all enabled webhook triggers against an event.
    /// Matching triggers fire the global webhook with a custom or auto-generated message.
    private func evaluateTriggers(_ event: [String: Any]) {
        let config = HomeClawConfig.shared
        guard let webhook = config.webhookConfig,
              webhook.enabled,
              let url = URL(string: webhook.url),
              !webhook.url.isEmpty
        else { return }

        let triggers = config.webhookTriggers
        guard !triggers.isEmpty else { return }

        let eventType = event["type"] as? String ?? ""
        let accessory = event["accessory"] as? [String: Any]
        let accessoryID = accessory?["id"] as? String
        let characteristic = event["characteristic"] as? String
        let value = event["value"] as? String
        let scene = event["scene"] as? [String: Any]
        let sceneID = scene?["id"] as? String
        let sceneName = scene?["name"] as? String

        for trigger in triggers where trigger.enabled {
            guard matchesTrigger(
                trigger,
                eventType: eventType,
                accessoryID: accessoryID,
                characteristic: characteristic,
                value: value,
                sceneID: sceneID,
                sceneName: sceneName
            ) else { continue }

            let text = trigger.message ?? formatEventText(event)
            let payload: [String: Any] = ["text": "[\(trigger.label)] \(text)", "mode": "now"]
            sendWebhookPayload(payload, to: url, token: webhook.token)
        }
    }

    private func matchesTrigger(
        _ trigger: HomeClawConfig.WebhookTrigger,
        eventType: String,
        accessoryID: String?,
        characteristic: String?,
        value: String?,
        sceneID: String?,
        sceneName: String?
    ) -> Bool {
        // Scene trigger match
        if let triggerSceneID = trigger.sceneID, !triggerSceneID.isEmpty {
            return eventType == "scene_triggered" && sceneID == triggerSceneID
        }
        if let triggerSceneName = trigger.sceneName, !triggerSceneName.isEmpty {
            return eventType == "scene_triggered"
                && sceneName?.localizedCaseInsensitiveCompare(triggerSceneName) == .orderedSame
        }

        // Accessory-based triggers (characteristic_change or accessory_controlled)
        guard eventType == "characteristic_change" || eventType == "accessory_controlled" else {
            return false
        }

        // Match by specific accessory ID
        if let triggerAccessoryID = trigger.accessoryID, !triggerAccessoryID.isEmpty {
            guard accessoryID == triggerAccessoryID else { return false }
        }

        // Match characteristic + value (if specified)
        if let triggerChar = trigger.characteristic, !triggerChar.isEmpty {
            guard characteristic?.localizedCaseInsensitiveCompare(triggerChar) == .orderedSame else {
                return false
            }
        }
        if let triggerValue = trigger.value, !triggerValue.isEmpty {
            guard value?.localizedCaseInsensitiveCompare(triggerValue) == .orderedSame else {
                return false
            }
        }

        // Must have at least one match condition
        let hasCondition = (trigger.accessoryID != nil && !trigger.accessoryID!.isEmpty)
            || (trigger.characteristic != nil && !trigger.characteristic!.isEmpty)
            || (trigger.value != nil && !trigger.value!.isEmpty)
        return hasCondition
    }

    // MARK: - Webhook

    private func deliverWebhook(_ event: [String: Any]) {
        let config = HomeClawConfig.shared
        guard let webhook = config.webhookConfig,
              webhook.enabled,
              let url = URL(string: webhook.url),
              !webhook.url.isEmpty
        else { return }

        // Check event type filter
        if let eventType = event["type"] as? String,
           let allowedEvents = webhook.events,
           !allowedEvents.isEmpty,
           !allowedEvents.contains(eventType)
        {
            return
        }

        let text = formatEventText(event)
        let payload: [String: Any] = ["text": text, "mode": "now"]
        sendWebhookPayload(payload, to: url, token: webhook.token)
    }

    private func sendWebhookPayload(_ payload: [String: Any], to url: URL, token: String) {
        // Circuit breaker (shared across general webhook and triggers)
        if webhookCircuitOpen {
            if let openedAt = webhookCircuitOpenedAt,
               Date().timeIntervalSince(openedAt) > webhookCircuitResetInterval
            {
                webhookCircuitOpen = false
                webhookFailureCount = 0
                logger.info("Webhook circuit breaker reset")
            } else {
                return
            }
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        request.timeoutInterval = 10

        let logger = self.logger
        Task.detached { [weak self] in
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    await self?.webhookFailed()
                    logger.warning("Webhook returned \(http.statusCode)")
                } else {
                    await self?.webhookSucceeded()
                }
            } catch {
                await self?.webhookFailed()
                logger.warning("Webhook delivery failed: \(error.localizedDescription)")
            }
        }
    }

    private func webhookFailed() {
        webhookFailureCount += 1
        if webhookFailureCount >= webhookCircuitThreshold {
            webhookCircuitOpen = true
            webhookCircuitOpenedAt = Date()
            logger.warning("Webhook circuit breaker opened after \(self.webhookCircuitThreshold) failures")
        }
    }

    private func webhookSucceeded() {
        webhookFailureCount = 0
    }

    private func formatEventText(_ event: [String: Any]) -> String {
        let type = event["type"] as? String ?? "unknown"
        switch type {
        case "characteristic_change":
            let accessory = event["accessory"] as? [String: Any]
            let name = accessory?["name"] as? String ?? "Unknown"
            let room = accessory?["room"] as? String
            let char = event["characteristic"] as? String ?? ""
            let value = event["value"] as? String ?? ""
            let location = room.map { " in \($0)" } ?? ""
            return "HomeKit: \(name)\(location) \(char) changed to \(value)"
        case "scene_triggered":
            let scene = event["scene"] as? [String: Any]
            let name = scene?["name"] as? String ?? "Unknown"
            return "HomeKit: Scene '\(name)' triggered"
        case "accessory_controlled":
            let accessory = event["accessory"] as? [String: Any]
            let name = accessory?["name"] as? String ?? "Unknown"
            let char = event["characteristic"] as? String ?? ""
            let value = event["value"] as? String ?? ""
            return "HomeKit: \(name) \(char) set to \(value)"
        case "homes_updated":
            let homes = event["homes"] as? Int ?? 0
            let accessories = event["accessories"] as? Int ?? 0
            return "HomeKit: Homes updated (\(homes) homes, \(accessories) accessories)"
        default:
            return "HomeKit event: \(type)"
        }
    }
}
