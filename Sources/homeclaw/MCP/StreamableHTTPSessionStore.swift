import Foundation

/// The state retained for one Streamable HTTP MCP connection.
/// The identifier is intentionally never included in logs.
struct StreamableHTTPSession: Sendable, Equatable {
    let createdAt: Date
    var lastAccessedAt: Date
}

/// Serializes session lifecycle and expiry cleanup for the HTTP transport.
actor StreamableHTTPSessionStore {
    private var sessions: [String: StreamableHTTPSession] = [:]
    private let ttl: TimeInterval
    private let maxSessions: Int

    init(ttl: TimeInterval = 3600, maxSessions: Int = 128) { self.ttl = ttl; self.maxSessions = maxSessions }

    func create(now: Date = Date()) -> String? {
        guard sessions.count < maxSessions else { return nil }
        let id = UUID().uuidString
        sessions[id] = StreamableHTTPSession(createdAt: now, lastAccessedAt: now)
        return id
    }

    func get(_ id: String) -> StreamableHTTPSession? { sessions[id] }

    @discardableResult
    func touch(_ id: String, now: Date = Date()) -> Bool {
        guard var session = sessions[id] else { return false }
        session.lastAccessedAt = now
        sessions[id] = session
        return true
    }

    /// Atomically validates that the session exists and has not expired, and refreshes its TTL.
    /// Returns false if missing or expired (expired entries are removed).
    @discardableResult
    func validateAndTouch(_ id: String, now: Date = Date()) -> Bool {
        guard var session = sessions[id] else { return false }
        if now.timeIntervalSince(session.lastAccessedAt) >= ttl {
            sessions.removeValue(forKey: id)
            return false
        }
        session.lastAccessedAt = now
        sessions[id] = session
        return true
    }

    @discardableResult
    func remove(_ id: String) -> Bool { sessions.removeValue(forKey: id) != nil }

    @discardableResult
    func removeAll() -> Int {
        let count = sessions.count
        sessions.removeAll()
        return count
    }

    func removeExpiredIDs(now: Date = Date()) -> [String] {
        let expired = sessions.filter { now.timeIntervalSince($0.value.lastAccessedAt) >= ttl }.map(\.key)
        expired.forEach { sessions.removeValue(forKey: $0) }
        return expired
    }

    @discardableResult
    func removeExpired(now: Date = Date()) -> Int {
        removeExpiredIDs(now: now).count
    }

    var count: Int { sessions.count }
}
