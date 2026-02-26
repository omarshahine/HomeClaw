import AppKit

/// AppKit-based menu bar controller loaded as a plugin bundle from the Catalyst app.
/// Conforms to `iOS2Mac` protocol so the Catalyst host can push HomeKit status updates.
///
/// This class creates an `NSStatusItem` (system menu bar icon) and manages an `NSMenu`
/// with home status, settings, and quit actions. It communicates back to the Catalyst
/// app via the `iOSBridge` (Mac2iOS) protocol reference.
@objc(MacOSController)
public class MacOSController: NSObject, iOS2Mac {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    @objc public var iOSBridge: (any Mac2iOS)?

    private var currentReady = false
    private var currentHomeNames: [String] = []

    public override required init() {
        super.init()
        setupStatusItem()
    }

    // MARK: - iOS2Mac Protocol

    public func updateStatus(ready: Bool, homeNames: [String]) {
        currentReady = ready
        currentHomeNames = homeNames
        rebuildMenu()
    }

    public func showError(message: String) {
        currentReady = false
        currentHomeNames = []
        rebuildMenu()
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        // Use variableLength — squareLength doesn't render correctly in Mac Catalyst's AppKit bridge
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "house.badge.wifi.fill", accessibilityDescription: "HomeClaw")
        }

        item.isVisible = true
        menu = NSMenu()
        item.menu = menu
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu else { return }
        menu.removeAllItems()

        // Status line
        if currentReady {
            let statusText = currentHomeNames.isEmpty ? "Connected" : currentHomeNames.joined(separator: ", ")
            let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
            statusItem.image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil)
            menu.addItem(statusItem)
        } else {
            let statusItem = NSMenuItem(title: "Waiting for HomeKit...", action: nil, keyEquivalent: "")
            statusItem.image = NSImage(systemSymbolName: "house", accessibilityDescription: nil)
            menu.addItem(statusItem)
        }

        menu.addItem(.separator())

        // Launch at Login
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        let isEnabled = iOSBridge?.isLaunchAtLoginEnabled ?? false
        launchItem.image = NSImage(
            systemSymbolName: isEnabled ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: isEnabled ? "Enabled" : "Disabled")
        menu.addItem(launchItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit HomeClaw", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func toggleLaunchAtLogin() {
        guard let bridge = iOSBridge else { return }
        let newValue = !bridge.isLaunchAtLoginEnabled
        bridge.setLaunchAtLogin(newValue)
        rebuildMenu()
    }

    @objc private func openSettings() {
        iOSBridge?.openSettings()
    }

    @objc private func quitApp() {
        iOSBridge?.quitApp()
    }
}
