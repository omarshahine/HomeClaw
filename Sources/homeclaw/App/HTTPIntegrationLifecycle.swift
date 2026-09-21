import Combine
import Foundation

/// The app owns one controller; settings only change its persisted intent.
@MainActor
final class HTTPIntegrationLifecycle: ObservableObject {
    static let enabledKey = "nativeMCPHTTPEnabled"
    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private let start: @MainActor () async throws -> Void
    private let stop: @MainActor () async -> Void
    private var pending: Task<Void, Never>?
    private var isShuttingDown = false

    init(defaults: UserDefaults = .standard,
         start: @escaping @MainActor () async throws -> Void,
         stop: @escaping @MainActor () async -> Void) {
        self.defaults = defaults
        self.start = start
        self.stop = stop
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    func startIfEnabled() {
        guard !isShuttingDown else { return }
        if isEnabled { schedule(enabled: true) }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isShuttingDown else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        schedule(enabled: enabled)
    }

    private func schedule(enabled: Bool) {
        // Do not overlap start/stop across actor suspension points. A stop must
        // await a pending bind, and a subsequent start must await full teardown.
        let previous = pending
        pending = Task {
            await previous?.value
            if enabled {
                guard isEnabled, !isShuttingDown else { return }
                do { try await start(); errorMessage = nil }
                catch { errorMessage = error.localizedDescription }
            } else {
                await stop()
                errorMessage = nil
            }
        }
    }

    func waitUntilSettled() async { await pending?.value }

    /// Synchronous cleanup must happen before returning from UIKit's final
    /// termination callback. Explicit Quit can additionally await this task.
    @discardableResult
    func beginShutdown(stopLegacy: () -> Void) -> Task<Void, Never> {
        if isShuttingDown, let pending { return pending }
        isShuttingDown = true
        stopLegacy()
        schedule(enabled: false)
        return pending!
    }
}
