import Foundation
import os

/// Tiered circuit breaker for webhook delivery.
///
/// State machine:
/// ```
/// closed ──(5 failures)──► softOpen ──(5 min)──► closed (auto-resume)
///                               │                      │
///                               │               (5 more failures)
///                               │                      │
///                               ◄──────────────────────┘
///                         (3 soft trips without
///                          any successful delivery)
///                               │
///                               ▼
///                          hardOpen ──(user toggles webhook off→on)──► closed
/// ```
///
/// Critical triggers (`agentDeliver: true`) always attempt delivery regardless of state.
/// State is runtime-only — app restart resets to closed.
@MainActor
final class WebhookCircuitBreaker {
    static let shared = WebhookCircuitBreaker()

    enum State: String, Sendable { case closed, softOpen, hardOpen }

    private(set) var state: State = .closed
    private(set) var consecutiveFailures = 0
    private(set) var softTripCount = 0
    private(set) var totalDroppedCount = 0
    private(set) var lastFailureDate: Date?
    private(set) var lastSuccessDate: Date?

    private var softOpenedAt: Date?
    private var resumeTask: Task<Void, Never>?

    private let logger = AppLogger.webhook

    // MARK: - Constants

    static let failureThreshold = 5
    static let softTripCooldown: TimeInterval = 300 // 5 minutes
    static let maxSoftTrips = 3

    // MARK: - Gate Check

    /// Returns true if the webhook should be attempted.
    /// Critical triggers always return true (and log a bypass).
    func shouldAllow(isCritical: Bool) -> Bool {
        switch state {
        case .closed:
            return true

        case .softOpen:
            if isCritical {
                logger.info("Circuit soft-open but allowing critical trigger")
                return true
            }
            totalDroppedCount += 1
            logger.debug("Webhook dropped (soft-open, \(self.remainingCooldownSeconds)s remaining)")
            return false

        case .hardOpen:
            if isCritical {
                logger.info("Circuit hard-open but allowing critical trigger")
                return true
            }
            totalDroppedCount += 1
            logger.debug("Webhook dropped (hard-open, manual reset required)")
            return false
        }
    }

    // MARK: - Recording

    func recordSuccess() {
        consecutiveFailures = 0
        softTripCount = 0
        lastSuccessDate = Date()

        if state == .softOpen {
            logger.info("Webhook succeeded during soft-open — resetting to closed")
            transition(to: .closed)
        }
    }

    func recordFailure() {
        consecutiveFailures += 1
        lastFailureDate = Date()

        if consecutiveFailures >= Self.failureThreshold && state == .closed {
            tripSoft()
        }
    }

    // MARK: - Manual Reset

    /// Full reset, called when user re-enables webhook or toggles off→on.
    func manualReset() {
        resumeTask?.cancel()
        resumeTask = nil
        consecutiveFailures = 0
        softTripCount = 0
        totalDroppedCount = 0
        softOpenedAt = nil
        transition(to: .closed)
        logger.info("Circuit breaker manually reset")
    }

    // MARK: - Computed

    var remainingCooldownSeconds: Int {
        guard state == .softOpen, let opened = softOpenedAt else { return 0 }
        let elapsed = Date().timeIntervalSince(opened)
        return max(0, Int(Self.softTripCooldown - elapsed))
    }

    // MARK: - Private

    private func tripSoft() {
        softTripCount += 1
        consecutiveFailures = 0

        if softTripCount >= Self.maxSoftTrips {
            transition(to: .hardOpen)
            logger.warning(
                "Circuit breaker hard-open after \(Self.maxSoftTrips) soft trips — manual reset required")
        } else {
            softOpenedAt = Date()
            transition(to: .softOpen)
            startResumeTimer()
            logger.warning(
                "Circuit breaker soft-open (trip \(self.softTripCount)/\(Self.maxSoftTrips)), auto-resume in \(Int(Self.softTripCooldown))s"
            )
        }
    }

    private func startResumeTimer() {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.softTripCooldown))
            guard !Task.isCancelled, self.state == .softOpen else { return }
            self.consecutiveFailures = 0
            self.softOpenedAt = nil
            self.transition(to: .closed)
            self.logger.info("Circuit breaker auto-resumed from soft-open")
        }
    }

    private func transition(to newState: State) {
        let oldState = state
        state = newState

        if oldState == .softOpen && newState != .softOpen {
            resumeTask?.cancel()
            resumeTask = nil
        }

        NotificationCenter.default.post(
            name: .webhookCircuitStateDidChange,
            object: nil,
            userInfo: [
                "state": newState.rawValue,
                "softTripCount": softTripCount,
                "remainingSeconds": remainingCooldownSeconds,
                "totalDropped": totalDroppedCount,
            ] as [String: Any]
        )
    }

    private init() {}
}
