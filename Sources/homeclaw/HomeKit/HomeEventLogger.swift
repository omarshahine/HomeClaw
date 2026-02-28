import Foundation
import os

/// Logs HomeKit events to a JSONL file in the App Group container.
/// Events are appended as newline-delimited JSON for efficient streaming reads.
/// Includes log rotation (max 1MB, 1 rotated backup) and optional webhook delivery.
@MainActor
final class HomeEventLogger {
    static let shared = HomeEventLogger()

    private let eventsFile: URL
    private let rotatedFile: URL
    private let maxFileSize: UInt64 = 1_048_576 // 1 MB
    private let fileManager = FileManager.default
    private let logger = AppLogger.homekit

    /// Webhook state
    private var webhookFailureCount = 0
    private var webhookCircuitOpen = false
    private var webhookCircuitOpenedAt: Date?
    private let webhookCircuitThreshold = 5
    private let webhookCircuitResetInterval: TimeInterval = 60

    private init() {
        let dir = HomeClawConfig.configDirectory
        eventsFile = dir.appendingPathComponent("events.jsonl")
        rotatedFile = dir.appendingPathComponent("events.jsonl.1")

        // Ensure directory exists
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
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
            "timestamp": ISO8601DateFormatter().string(from: Date()),
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
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "type": EventType.homesUpdated.rawValue,
            "homes": homeCount,
            "accessories": accessoryCount,
        ]
        writeEvent(event)
    }

    /// Logs a scene trigger event.
    func logSceneTriggered(sceneID: String, sceneName: String, homeName: String?) {
        var event: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
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
            "timestamp": ISO8601DateFormatter().string(from: Date()),
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
                break // Events are chronological, so once we're past `since`, stop
            }

            events.append(event)
            if events.count >= limit { break }
        }

        return events
    }

    // MARK: - Private

    private func writeEvent(_ event: [String: Any]) {
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

        // Fire webhook asynchronously
        deliverWebhook(event)
    }

    private func rotateIfNeeded() {
        guard let attrs = try? fileManager.attributesOfItem(atPath: eventsFile.path),
              let size = attrs[.size] as? UInt64,
              size >= maxFileSize
        else { return }

        // Remove old rotated file, move current to .1
        try? fileManager.removeItem(at: rotatedFile)
        try? fileManager.moveItem(at: eventsFile, to: rotatedFile)
        logger.info("Event log rotated")
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

        // Circuit breaker
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

        // Build the webhook payload to match OpenClaw /hooks/wake format
        let text = formatEventText(event)
        let payload: [String: Any] = [
            "text": text,
            "mode": "now",
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !webhook.token.isEmpty {
            request.setValue("Bearer \(webhook.token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        request.timeoutInterval = 10

        // Fire and forget — capture self weakly to avoid retain cycles
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
            logger.warning("Webhook circuit breaker opened after \(webhookCircuitThreshold) failures")
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
