import Foundation

/// Protocol for the Catalyst app to expose state to the macOS bridge bundle.
/// The macOSBridge bundle calls these methods via its `iOSBridge` reference.
@MainActor
@objc(Mac2iOS) public protocol Mac2iOS: NSObjectProtocol {
    var isLaunchAtLoginEnabled: Bool { get }
    func setLaunchAtLogin(_ enabled: Bool)
    func refreshData()
    func openSettings()
    func quitApp()
    func controlAccessory(id: String, characteristic: String, value: String)
    func triggerScene(id: String)
    func selectHome(id: String)
}

/// Protocol for the macOS bridge bundle (NSStatusItem menu bar) to receive updates.
/// The Catalyst app calls these methods when HomeKit state changes.
@MainActor
@objc(iOS2Mac) public protocol iOS2Mac: NSObjectProtocol {
    init()
    var iOSBridge: (any Mac2iOS)? { get set }
    func updateStatus(ready: Bool, homeNames: [String])
    func updateMenuData(_ data: [String: Any])
    func showError(message: String)
    func flashError()
}
