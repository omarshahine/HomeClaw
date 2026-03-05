import Foundation
import os

/// Dedicated log for webhook delivery events.
/// Records every webhook decision (delivered, failed, dropped, skipped) as JSONL
/// in `webhooks.jsonl` alongside the main event log.
@MainActor
final class WebhookEventLogger {
    static let shared = WebhookEventLogger()

    private let logDir: URL
    private let logFile: URL
    private let fileManager = FileManager.default
    private let logger = AppLogger.webhook
    private static let isoFormatter = ISO8601DateFormatter()

    /// Max file size in bytes (5 MB default — webhook log is much smaller than event log).
    private let maxFileSize: UInt64 = 5 * 1_048_576
    private let maxBackups = 2

    private init() {
        logDir = HomeClawConfig.configDirectory
        logFile = logDir.appendingPathComponent("webhooks.jsonl")
        try? fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
    }

    // MARK: - Outcome Types

    enum Outcome: String {
        case delivered            // 2xx response
        case failed               // HTTP error or network failure
        case dropped              // Circuit breaker blocked
        case skipped              // Battery filter or no matching trigger
    }

    // MARK: - Logging

    /// Logs a webhook delivery outcome.
    func log(
        outcome: Outcome,
        triggerID: String? = nil,
        triggerLabel: String? = nil,
        endpoint: String? = nil,
        accessoryName: String? = nil,
        characteristic: String? = nil,
        httpStatus: Int? = nil,
        error: String? = nil,
        circuitState: String? = nil,
        reason: String? = nil
    ) {
        var entry: [String: Any] = [
            "timestamp": Self.isoFormatter.string(from: Date()),
            "outcome": outcome.rawValue,
        ]
        if let triggerID { entry["trigger_id"] = triggerID }
        if let triggerLabel { entry["trigger_label"] = triggerLabel }
        if let endpoint { entry["endpoint"] = endpoint }
        if let accessoryName { entry["accessory"] = accessoryName }
        if let characteristic { entry["characteristic"] = characteristic }
        if let httpStatus { entry["http_status"] = httpStatus }
        if let error { entry["error"] = error }
        if let circuitState { entry["circuit_state"] = circuitState }
        if let reason { entry["reason"] = reason }

        writeEntry(entry)
    }

    // MARK: - Reading

    /// Reads webhook log entries, newest first.
    /// Scans the active log file and backup files to ensure complete results
    /// when a `since` window spans a log rotation boundary.
    func readEntries(
        since: Date? = nil,
        limit: Int = 100,
        outcome: Outcome? = nil
    ) -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        var entries: [[String: Any]] = []

        // Scan active file first, then backups (newest to oldest)
        var filesToScan = [logFile]
        for i in 1...maxBackups {
            let backup = logDir.appendingPathComponent("webhooks.jsonl.\(i)")
            if fileManager.fileExists(atPath: backup.path) {
                filesToScan.append(backup)
            }
        }

        for file in filesToScan {
            guard entries.count < limit else { break }

            guard let data = try? Data(contentsOf: file),
                  let content = String(data: data, encoding: .utf8)
            else { continue }

            let lines = content.components(separatedBy: "\n").reversed()
            var reachedSinceBoundary = false

            for line in lines {
                guard !line.isEmpty else { continue }
                guard let lineData = line.data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                else { continue }

                if let outcome, entry["outcome"] as? String != outcome.rawValue {
                    continue
                }

                if let since, let ts = entry["timestamp"] as? String,
                   let entryDate = formatter.date(from: ts), entryDate < since
                {
                    reachedSinceBoundary = true
                    break
                }

                entries.append(entry)
                if entries.count >= limit { break }
            }

            // If we hit the since boundary in this file, no need to check older backups
            if reachedSinceBoundary { break }
        }

        return entries
    }

    // MARK: - Stats

    func logStats() -> [String: Any] {
        var totalSize: UInt64 = 0
        var fileCount = 0

        if let attrs = try? fileManager.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? UInt64
        {
            totalSize += size
            fileCount += 1
        }

        for i in 1...max(1, maxBackups) {
            let backup = logDir.appendingPathComponent("webhooks.jsonl.\(i)")
            if let attrs = try? fileManager.attributesOfItem(atPath: backup.path),
               let size = attrs[.size] as? UInt64
            {
                totalSize += size
                fileCount += 1
            }
        }

        return [
            "file_count": fileCount,
            "total_size_bytes": totalSize,
            "total_size_mb": String(format: "%.1f", Double(totalSize) / 1_048_576),
            "path": logFile.path,
        ]
    }

    // MARK: - Management

    func purge() {
        try? fileManager.removeItem(at: logFile)
        for i in 1...10 {
            let backup = logDir.appendingPathComponent("webhooks.jsonl.\(i)")
            try? fileManager.removeItem(at: backup)
        }
        logger.info("Webhook log purged")
    }

    // MARK: - Private

    private func writeEntry(_ entry: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              var line = String(data: jsonData, encoding: .utf8)
        else { return }

        line += "\n"

        rotateIfNeeded()

        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.data(using: .utf8)?.write(to: logFile, options: .atomic)
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? fileManager.attributesOfItem(atPath: logFile.path),
              let size = attrs[.size] as? UInt64,
              size >= maxFileSize
        else { return }

        for i in stride(from: maxBackups, through: 1, by: -1) {
            let src = logDir.appendingPathComponent("webhooks.jsonl.\(i)")
            if i >= maxBackups {
                try? fileManager.removeItem(at: src)
            } else {
                let dst = logDir.appendingPathComponent("webhooks.jsonl.\(i + 1)")
                try? fileManager.removeItem(at: dst)
                try? fileManager.moveItem(at: src, to: dst)
            }
        }

        let dst = logDir.appendingPathComponent("webhooks.jsonl.1")
        try? fileManager.removeItem(at: dst)
        try? fileManager.moveItem(at: logFile, to: dst)

        logger.info("Webhook log rotated")
    }
}
