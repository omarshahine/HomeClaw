import Foundation

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

    func cancelAll() -> [String] {
        let sessions = activeSessionIDs
        activeTaskIDs.removeAll()
        activeSessionIDs.removeAll()
        activeSSESessionIDs.removeAll()
        activeSSEOwnerships.removeAll()
        taskSessions.removeAll()
        return sessions.sorted()
    }

    private func retireSessionIfUnused(_ sessionID: String?) {
        guard let sessionID,
              !activeSSESessionIDs.contains(sessionID),
              !taskSessions.values.contains(where: { $0 == sessionID }) else { return }
        activeSessionIDs.remove(sessionID)
    }
}
