import Foundation
#if !LIFECYCLE_STANDALONE
import XCTest
@testable import HomeClaw
#endif

@MainActor
private enum LifecycleChecks {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    @MainActor final class Gate {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func open() { continuation?.resume(); continuation = nil }
    }

    static func disableDuringStartup() async throws {
        let suite = "HTTPIntegrationLifecycleTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = Gate()
        var listening = false
        let lifecycle = HTTPIntegrationLifecycle(defaults: defaults, start: {
            await gate.wait()
            listening = true
        }, stop: { listening = false })
        lifecycle.setEnabled(true)
        while gate.continuation == nil { await Task.yield() }
        lifecycle.setEnabled(false)
        // Let a naively concurrent stop finish before the suspended start.
        for _ in 0..<20 { await Task.yield() }
        gate.open()
        for _ in 0..<20 { await Task.yield() }
        await lifecycle.waitUntilSettled()
        try expect(!listening, "Disable during suspended startup must close the late listener")
    }

    static func shutdownPreventsRestartAndWaitsForHTTP() async throws {
        let suite = "HTTPIntegrationLifecycleTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = Gate()
        var events: [String] = []
        let lifecycle = HTTPIntegrationLifecycle(defaults: defaults, start: {
            events.append("start")
        }, stop: {
            events.append("http-stopping")
            await gate.wait()
            events.append("http-stopped")
        })
        lifecycle.setEnabled(true)
        await lifecycle.waitUntilSettled()
        let shutdown = lifecycle.beginShutdown { events.append("socket-stopped") }
        try expect(events == ["start", "socket-stopped"], "Legacy stop must execute synchronously")
        lifecycle.setEnabled(true)
        lifecycle.startIfEnabled()
        let completion = Task { await shutdown.value; events.append("terminate") }
        while gate.continuation == nil { await Task.yield() }
        try expect(!events.contains("terminate"), "Termination must wait for HTTP cleanup without blocking MainActor")
        gate.open()
        await completion.value
        await lifecycle.waitUntilSettled()
        try expect(events == ["start", "socket-stopped", "http-stopping", "http-stopped", "terminate"], "Shutdown must prevent restarts and complete before termination")
        try expect(defaults.bool(forKey: HTTPIntegrationLifecycle.enabledKey), "Quit must preserve preference for next launch")
    }

    static func rapidTogglesDoNotStartAfterDisable() async throws {
        let suite = "HTTPIntegrationLifecycleTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var starts = 0
        let lifecycle = HTTPIntegrationLifecycle(defaults: defaults, start: { starts += 1 }, stop: {})
        lifecycle.setEnabled(true)
        lifecycle.setEnabled(false)
        lifecycle.setEnabled(true)
        lifecycle.setEnabled(false)
        await lifecycle.waitUntilSettled()
        try expect(starts == 0, "Queued enables must not start after final disable")
    }

    static func defaultOffAndPersistence() async throws {
        let suite = "HTTPIntegrationLifecycleTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var starts = 0
        let lifecycle = HTTPIntegrationLifecycle(defaults: defaults, start: { starts += 1 }, stop: {})
        lifecycle.startIfEnabled()
        await lifecycle.waitUntilSettled()
        try expect(!lifecycle.isEnabled && starts == 0, "Absent setting must not start HTTP")
        lifecycle.setEnabled(true)
        await lifecycle.waitUntilSettled()
        try expect(starts == 1, "Enabling starts HTTP")
        let restored = HTTPIntegrationLifecycle(defaults: defaults, start: { starts += 1 }, stop: {})
        try expect(restored.isEnabled, "Enabled preference must persist")
        lifecycle.setEnabled(false)
        await lifecycle.waitUntilSettled()
        try expect(!defaults.bool(forKey: HTTPIntegrationLifecycle.enabledKey), "Disabled preference must persist")
    }
}

#if LIFECYCLE_STANDALONE
@main
struct HTTPIntegrationLifecycleTestRunner {
    static func main() async throws {
        try await LifecycleChecks.defaultOffAndPersistence()
        print("PASS defaultOffAndPersistence")
        try await LifecycleChecks.disableDuringStartup()
        print("PASS disableDuringStartup")
        try await LifecycleChecks.shutdownPreventsRestartAndWaitsForHTTP()
        print("PASS shutdownPreventsRestartAndWaitsForHTTP")
        try await LifecycleChecks.rapidTogglesDoNotStartAfterDisable()
        print("PASS rapidTogglesDoNotStartAfterDisable")
    }
}
#else
final class HTTPIntegrationLifecycleTests: XCTestCase {
    @MainActor func testRapidTogglesDoNotStartAfterDisable() async throws {
        try await LifecycleChecks.rapidTogglesDoNotStartAfterDisable()
    }
    @MainActor func testDisableDuringStartup() async throws {
        try await LifecycleChecks.disableDuringStartup()
    }
    @MainActor func testShutdownPreventsRestartAndWaitsForHTTP() async throws {
        try await LifecycleChecks.shutdownPreventsRestartAndWaitsForHTTP()
    }
    @MainActor func testDefaultOffAndPersistence() async throws {
        try await LifecycleChecks.defaultOffAndPersistence()
    }
}
#endif
