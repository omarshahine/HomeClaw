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
        previousValue: String?,
        homeName: String? = nil,
        homeID: String? = nil
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
        if let homeName {
            var homeDict: [String: Any] = ["name": homeName]
            if let homeID { homeDict["id"] = homeID }
            event["home"] = homeDict
        }
        writeEvent(event)
    }

    /// Logs a homes updated event from the HMHomeManagerDelegate callback.
    func logHomesUpdated(homeCount: Int, accessoryCount: Int, homeNames: [String] = []) {
        var event: [String: Any] = [
            "timestamp": Self.isoFormatter.string(from: Date()),
            "type": EventType.homesUpdated.rawValue,
            "homes": homeCount,
            "accessories": accessoryCount,
        ]
        if !homeNames.isEmpty {
            event["home_names"] = homeNames
        }
        writeEvent(event)
    }

    /// Logs a scene trigger event.
    func logSceneTriggered(sceneID: String, sceneName: String, homeName: String?, homeID: String? = nil) {
        var event: [String: Any] = [
            "timestamp": Self.isoFormatter.string(from: Date()),
            "type": EventType.sceneTriggered.rawValue,
            "scene": [
                "id": sceneID,
                "name": sceneName,
            ] as [String: Any],
        ]
        if let homeName {
            var homeDict: [String: Any] = ["name": homeName]
            if let homeID { homeDict["id"] = homeID }
            event["home"] = homeDict
        }
        writeEvent(event)
    }

    /// Logs an accessory control event (user set a value via CLI/MCP).
    func logAccessoryControlled(
        accessoryID: String,
        accessoryName: String,
        characteristic: String,
        value: String,
        homeName: String? = nil,
        homeID: String? = nil
    ) {
        var event: [String: Any] = [
            "timestamp": Self.isoFormatter.string(from: Date()),
            "type": EventType.accessoryControlled.rawValue,
            "accessory": [
                "id": accessoryID,
                "name": accessoryName,
            ] as [String: Any],
            "characteristic": characteristic,
            "value": value,
        ]
        if let homeName {
            var homeDict: [String: Any] = ["name": homeName]
            if let homeID { homeDict["id"] = homeID }
            event["home"] = homeDict
        }
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

        // Only fire webhooks for events that match a configured trigger.
        // No catch-all — untriggered events are logged but not pushed.
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

    /// Battery-related characteristics that should never trigger webhooks.
    /// These change frequently and are not actionable state transitions.
    private static let webhookExcludedCharacteristics: Set<String> = [
        "battery_level", "low_battery",
    ]

    /// Evaluates all enabled webhook triggers against an event.
    /// Matching triggers fire webhooks routed by action type (wake or agent).
    /// Returns true if at least one trigger matched (so the caller can skip the general webhook).
    @discardableResult
    private func evaluateTriggers(_ event: [String: Any]) -> Bool {
        let config = HomeClawConfig.shared
        guard let webhook = config.webhookConfig,
              webhook.enabled,
              !webhook.url.isEmpty
        else { return false }

        let triggers = config.webhookTriggers
        guard !triggers.isEmpty else { return false }

        let baseURL = webhook.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let eventType = event["type"] as? String ?? ""
        let accessory = event["accessory"] as? [String: Any]
        let accessoryID = accessory?["id"] as? String
        let characteristic = event["characteristic"] as? String
        let value = event["value"] as? String

        // Skip battery-related characteristics — they are not actionable state changes
        if let characteristic, Self.webhookExcludedCharacteristics.contains(characteristic) {
            let accessoryName = (event["accessory"] as? [String: Any])?["name"] as? String
            WebhookEventLogger.shared.log(
                outcome: .skipped,
                accessoryName: accessoryName,
                characteristic: characteristic,
                reason: "battery_characteristic"
            )
            return false
        }
        let scene = event["scene"] as? [String: Any]
        let sceneID = scene?["id"] as? String
        let sceneName = scene?["name"] as? String

        var matched = false
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

            matched = true
            let action = trigger.action ?? "wake"
            let text = trigger.message ?? formatEventText(event)
            let isCritical = trigger.agentDeliver == true

            let accessoryName = (event["accessory"] as? [String: Any])?["name"] as? String

            if action == "agent" {
                guard let url = URL(string: baseURL + "/hooks/agent") else { continue }
                let payload = buildAgentPayload(trigger: trigger, eventText: text)
                sendWebhookPayload(
                    payload, to: url, token: webhook.token, timeout: 30,
                    isCritical: isCritical, trigger: trigger,
                    accessoryName: accessoryName, characteristic: characteristic
                )
            } else {
                guard let url = URL(string: baseURL + "/hooks/wake") else { continue }
                // Default wake mode is "next-heartbeat" (batched) for ambient events.
                // Security triggers should set wakeMode: "now" explicitly.
                let mode = trigger.wakeMode ?? "next-heartbeat"
                let payload: [String: Any] = ["text": "[\(trigger.label)] \(text)", "mode": mode]
                sendWebhookPayload(
                    payload, to: url, token: webhook.token,
                    isCritical: isCritical, trigger: trigger,
                    accessoryName: accessoryName, characteristic: characteristic
                )
            }
        }
        return matched
    }

    /// Builds the JSON payload for an agent webhook call.
    private func buildAgentPayload(trigger: HomeClawConfig.WebhookTrigger, eventText: String) -> [String: Any] {
        var payload: [String: Any] = [
            "message": trigger.agentPrompt ?? "[\(trigger.label)] \(eventText)",
            "name": trigger.agentName ?? "HomeClaw",
        ]
        if let agentId = trigger.agentId, !agentId.isEmpty {
            payload["agentId"] = agentId
        }
        if let wakeMode = trigger.wakeMode {
            payload["wakeMode"] = wakeMode
        }
        if let deliver = trigger.agentDeliver {
            payload["deliver"] = deliver
        }
        return payload
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

    private func sendWebhookPayload(
        _ payload: [String: Any], to url: URL, token: String,
        timeout: TimeInterval = 10, isCritical: Bool = false,
        trigger: HomeClawConfig.WebhookTrigger? = nil,
        accessoryName: String? = nil, characteristic: String? = nil
    ) {
        let webhookLog = WebhookEventLogger.shared
        let endpoint = url.path

        guard WebhookCircuitBreaker.shared.shouldAllow(isCritical: isCritical) else {
            webhookLog.log(
                outcome: .dropped,
                triggerID: trigger?.id, triggerLabel: trigger?.label,
                endpoint: endpoint, accessoryName: accessoryName,
                characteristic: characteristic,
                circuitState: WebhookCircuitBreaker.shared.state.rawValue,
                reason: "circuit_breaker"
            )
            return
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // Idempotency — lets the receiver deduplicate retried deliveries
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        request.setValue(Self.isoFormatter.string(from: Date()), forHTTPHeaderField: "X-Event-Timestamp")
        request.httpBody = body
        request.timeoutInterval = timeout

        let logger = self.logger
        let triggerID = trigger?.id
        let triggerLabel = trigger?.label
        Task.detached {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    await WebhookCircuitBreaker.shared.recordFailure(httpStatus: http.statusCode)
                    await webhookLog.log(
                        outcome: .failed,
                        triggerID: triggerID, triggerLabel: triggerLabel,
                        endpoint: endpoint, accessoryName: accessoryName,
                        characteristic: characteristic,
                        httpStatus: http.statusCode
                    )
                    logger.warning("Webhook returned \(http.statusCode)")
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                    await WebhookCircuitBreaker.shared.recordSuccess(httpStatus: status)
                    await webhookLog.log(
                        outcome: .delivered,
                        triggerID: triggerID, triggerLabel: triggerLabel,
                        endpoint: endpoint, accessoryName: accessoryName,
                        characteristic: characteristic,
                        httpStatus: status
                    )
                }
            } catch {
                await WebhookCircuitBreaker.shared.recordFailure()
                await webhookLog.log(
                    outcome: .failed,
                    triggerID: triggerID, triggerLabel: triggerLabel,
                    endpoint: endpoint, accessoryName: accessoryName,
                    characteristic: characteristic,
                    error: error.localizedDescription
                )
                logger.warning("Webhook delivery failed: \(error.localizedDescription)")
            }
        }
    }

    /// Extracts the home name from an event's `home` field.
    /// Handles both the new dict format `{"name": "...", "id": "..."}` and legacy string format.
    private func homeLabel(from event: [String: Any]) -> String? {
        if let homeDict = event["home"] as? [String: Any] {
            return homeDict["name"] as? String
        }
        return event["home"] as? String
    }

    private func formatEventText(_ event: [String: Any]) -> String {
        let type = event["type"] as? String ?? "unknown"
        let homePrefix = homeLabel(from: event).map { "[\($0)] " } ?? ""

        switch type {
        case "characteristic_change":
            let accessory = event["accessory"] as? [String: Any]
            let name = accessory?["name"] as? String ?? "Unknown"
            let room = accessory?["room"] as? String
            let char = event["characteristic"] as? String ?? ""
            let value = event["value"] as? String ?? ""
            let location = room.map { " in \($0)" } ?? ""
            return "\(homePrefix)HomeKit: \(name)\(location) \(char) changed to \(value)"
        case "scene_triggered":
            let scene = event["scene"] as? [String: Any]
            let name = scene?["name"] as? String ?? "Unknown"
            return "\(homePrefix)HomeKit: Scene '\(name)' triggered"
        case "accessory_controlled":
            let accessory = event["accessory"] as? [String: Any]
            let name = accessory?["name"] as? String ?? "Unknown"
            let char = event["characteristic"] as? String ?? ""
            let value = event["value"] as? String ?? ""
            return "\(homePrefix)HomeKit: \(name) \(char) set to \(value)"
        case "homes_updated":
            let homes = event["homes"] as? Int ?? 0
            let accessories = event["accessories"] as? Int ?? 0
            let homeNames = event["home_names"] as? [String]
            let namesSuffix = homeNames.map { ": \($0.joined(separator: ", "))" } ?? ""
            return "HomeKit: Homes updated (\(homes) homes, \(accessories) accessories)\(namesSuffix)"
        default:
            return "\(homePrefix)HomeKit event: \(type)"
        }
    }
}
