import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppLogger.app.info("HomeClaw starting...")

        // Launch HomeKit Helper and begin health monitoring
        HelperManager.shared.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.app.info("HomeClaw shutting down...")
        HelperManager.shared.stopMonitoring()
    }
}
