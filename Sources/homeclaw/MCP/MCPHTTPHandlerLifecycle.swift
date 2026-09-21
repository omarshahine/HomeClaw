import Foundation
@preconcurrency import NIOCore

/// A per-channel FIFO gate for HTTP/1.1 response writes.
///
/// Requests may execute concurrently, but a response cannot begin until every
/// earlier request on the channel has finished writing its response.
final class MCPHTTPResponseOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var nextTicket = 0
    private var nextToWrite = 0
    private var completed: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func reserve() -> Int {
        lock.lock(); defer { lock.unlock() }
        defer { nextTicket += 1 }
        return nextTicket
    }

    func waitTurn(_ ticket: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            let canProceed = ticket < nextToWrite || completed.contains(ticket) || ticket == nextToWrite
            if !canProceed { waiters[ticket] = continuation }
            lock.unlock()
            if canProceed { continuation.resume() }
        }
    }

    func finish(_ ticket: Int) {
        var resumptions: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        if ticket >= nextToWrite {
            completed.insert(ticket)
            while completed.remove(nextToWrite) != nil {
                if let continuation = waiters.removeValue(forKey: nextToWrite) {
                    resumptions.append(continuation)
                }
                nextToWrite += 1
            }
            // Advancing the frontier makes the next unfinished response eligible.
            // It may already be suspended in waitTurn; wake it, not just tickets
            // marked completed by cancellation or out-of-order completion.
            if let continuation = waiters.removeValue(forKey: nextToWrite) {
                resumptions.append(continuation)
            }
        }
        lock.unlock()
        resumptions.forEach { $0.resume() }
    }

    func cancelAll() {
        var resumptions: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        completed.formUnion(nextToWrite..<nextTicket)
        while completed.remove(nextToWrite) != nil {
            if let continuation = waiters.removeValue(forKey: nextToWrite) {
                resumptions.append(continuation)
            }
            nextToWrite += 1
        }
        lock.unlock()
        resumptions.forEach { $0.resume() }
    }
}

/// Event-loop-confined bookkeeping for request tasks and SSE sessions.
///
/// This type intentionally stores only task handles and identifiers. Request
/// closures are owned by their Task and are not retained by lifecycle state.
final class MCPHTTPHandlerLifecycle {
    private(set) var activeTaskIDs: Set<UUID> = []
    private(set) var activeSessionIDs: Set<String> = []
    private(set) var activeSSESessionIDs: Set<String> = []
    private(set) var activeSSEOwnerships: Set<SSEStreamOwnership> = []
    private var taskSessions: [UUID: String?] = [:]

    func begin(taskID: UUID, sessionID: String?) {
        activeTaskIDs.insert(taskID)
        taskSessions[taskID] = sessionID
        if let sessionID { activeSessionIDs.insert(sessionID) }
    }

    func markSSEActive(_ ownership: SSEStreamOwnership) {
        activeSSEOwnerships.insert(ownership)
        activeSSESessionIDs.insert(ownership.sessionID)
        activeSessionIDs.insert(ownership.sessionID)
    }

    func finish(taskID: UUID) {
        guard activeTaskIDs.remove(taskID) != nil else { return }
        let sessionID = taskSessions.removeValue(forKey: taskID) ?? nil
        retireSessionIfUnused(sessionID)
    }

    func finishSSE(_ ownership: SSEStreamOwnership) {
        guard activeSSEOwnerships.remove(ownership) != nil else { return }
        if !activeSSEOwnerships.contains(where: { $0.sessionID == ownership.sessionID }) {
            activeSSESessionIDs.remove(ownership.sessionID)
        }
        retireSessionIfUnused(ownership.sessionID)
    }

    /// Only streams owned by this channel may be retired on disconnect. A POST
    /// borrows a session ID; it does not own that session's stream.
    func cancelAll() -> Set<SSEStreamOwnership> {
        let ownerships = activeSSEOwnerships
        activeTaskIDs.removeAll()
        activeSessionIDs.removeAll()
        activeSSESessionIDs.removeAll()
        activeSSEOwnerships.removeAll()
        taskSessions.removeAll()
        return ownerships
    }

    private func retireSessionIfUnused(_ sessionID: String?) {
        guard let sessionID,
              !activeSSESessionIDs.contains(sessionID),
              !taskSessions.values.contains(where: { $0 == sessionID }) else { return }
        activeSessionIDs.remove(sessionID)
    }
}

/// Server-wide bookkeeping shared by every child channel of one listener.
///
/// It enforces the concurrent-connection cap and records every request task so
/// `MCPServer.stop()` can close the connections and wait for in-flight work to
/// drain *before* shutting the event loop group down. Without that drain, a
/// task finishing after shutdown would call `eventLoop.execute` on a dead loop,
/// which SwiftNIO reports as an error today and will turn into a crash.
final class MCPHTTPConnectionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let maxConnections: Int
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var finishedBeforeTracking: Set<UUID> = []
    private var isShutDown = false

    init(maxConnections: Int = .max) { self.maxConnections = maxConnections }

    var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return channels.count }
    var taskCount: Int { lock.lock(); defer { lock.unlock() }; return tasks.count }

    /// Admits a new child channel, or returns false when the cap is reached or
    /// the listener is shutting down. Admitted channels release themselves on close.
    func admit(_ channel: Channel) -> Bool {
        let key = ObjectIdentifier(channel)
        lock.lock()
        guard !isShutDown, channels.count < maxConnections else { lock.unlock(); return false }
        channels[key] = channel
        lock.unlock()
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.channels.removeValue(forKey: key); self.lock.unlock()
        }
        return true
    }

    func track(_ id: UUID, _ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if finishedBeforeTracking.remove(id) != nil { return }
        tasks[id] = task
    }

    func finish(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if tasks.removeValue(forKey: id) == nil { finishedBeforeTracking.insert(id) }
    }

    /// Stops admitting connections, closes every open one (which cancels their
    /// request tasks via `channelInactive`), and waits for tracked tasks to end.
    func shutdown() async {
        for channel in beginShutdown() { channel.close(promise: nil) }
        // Each task untracks itself in its final `defer`, so once its value is
        // available it is gone; loop to catch tasks that started meanwhile.
        while case let pending = pendingTasks(), !pending.isEmpty {
            for task in pending { task.cancel(); await task.value }
        }
    }

    private func beginShutdown() -> [Channel] {
        lock.lock(); defer { lock.unlock() }
        isShutDown = true
        return Array(channels.values)
    }

    private func pendingTasks() -> [Task<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        return Array(tasks.values)
    }
}
