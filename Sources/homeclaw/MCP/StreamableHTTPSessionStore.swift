import Foundation

/// The state retained for one Streamable HTTP MCP connection.
/// The identifier is intentionally never included in logs.
struct StreamableHTTPSession: Sendable, Equatable {
    let createdAt: Date
    var lastAccessedAt: Date
    /// The protocol version negotiated by `initialize`. Used when a later
    /// request omits `MCP-Protocol-Version` (the spec's "other way to identify
    /// the version").
    let protocolVersion: String
}

/// Serializes session lifecycle and expiry cleanup for the HTTP transport.
actor StreamableHTTPSessionStore {
    struct Created: Sendable, Equatable {
        let id: String
        /// A live session evicted to make room. Its SSE stream must be finished.
        let evicted: String?
    }

    private var sessions: [String: StreamableHTTPSession] = [:]
    private let ttl: TimeInterval
    private let maxSessions: Int

    init(ttl: TimeInterval = 3600, maxSessions: Int = 128) { self.ttl = ttl; self.maxSessions = maxSessions }

    /// Creates a session. When the store is full, expired sessions are dropped
    /// first; if it is still full, the least-recently-used session is evicted so
    /// a flood of abandoned sessions can never lock new clients out. Sessions in
    /// `protected` (those with a live SSE stream) are evicted only when every
    /// session is protected. An evicted client gets 404 and re-initializes.
    func create(protocolVersion: String = MCPServer.latestProtocolVersion, protected: Set<String> = [], now: Date = Date()) -> Created? {
        guard maxSessions > 0 else { return nil }
        var evicted: String?
        if sessions.count >= maxSessions { _ = removeExpiredIDs(now: now) }
        if sessions.count >= maxSessions {
            let byAge = sessions.sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
            let victim = byAge.first { !protected.contains($0.key) } ?? byAge.first
            if let victim { sessions.removeValue(forKey: victim.key); evicted = victim.key }
        }
        let id = UUID().uuidString
        sessions[id] = StreamableHTTPSession(createdAt: now, lastAccessedAt: now, protocolVersion: protocolVersion)
        return Created(id: id, evicted: evicted)
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
    /// Returns the live session, or nil if missing or expired (expired entries are removed).
    @discardableResult
    func validateAndTouch(_ id: String, now: Date = Date()) -> StreamableHTTPSession? {
        guard var session = sessions[id] else { return nil }
        if now.timeIntervalSince(session.lastAccessedAt) >= ttl {
            sessions.removeValue(forKey: id)
            return nil
        }
        session.lastAccessedAt = now
        sessions[id] = session
        return session
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
