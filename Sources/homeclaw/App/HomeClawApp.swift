#if canImport(ServiceManagement)
import ServiceManagement
#endif
import SwiftUI
import UIKit

/// Unified Mac Catalyst app that provides HomeKit access, a socket server for
/// CLI/MCP clients, and a native macOS menu bar via the macOSBridge plugin bundle.
///
/// This replaces the previous two-process architecture (native macOS + Catalyst helper).
/// HomeKit access is now in-process, eliminating the IPC overhead and provisioning
/// profile conflicts that prevented App Store submission.
@main
class HomeClawApp: UIResponder, UIApplicationDelegate, Mac2iOS {

    private var macOSController: (any iOS2Mac)?
    private var homeKitObserver: NSObjectProtocol?

    // MARK: - Mac2iOS Protocol

    @objc var isLaunchAtLoginEnabled: Bool {
        #if canImport(ServiceManagement)
        SMAppService.mainApp.status == .enabled
        #else
        false
        #endif
    }

    @objc func setLaunchAtLogin(_ enabled: Bool) {
        #if canImport(ServiceManagement)
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            AppLogger.app.info("Launch at login set to \(enabled)")
        } catch {
            AppLogger.app.error("Launch at login toggle failed: \(error.localizedDescription)")
        }
        #endif
    }

    @objc func refreshData() {
        Task { @MainActor in
            _ = await HomeKitManager.shared.refreshCache()
        }
    }

    @objc func openSettings() {
        let activity = NSUserActivity(activityType: "com.shahine.homeclaw.settings")
        UIApplication.shared.requestSceneSessionActivation(
            nil, userActivity: activity, options: nil)
    }

    @objc func quitApp() {
        // Clean up socket before exit
        SocketServer.shared.stop()

        #if targetEnvironment(macCatalyst)
        // Use NSApplication to terminate cleanly
        if let nsAppClass: AnyClass = NSClassFromString("NSApplication"),
           let metaclass = object_getClass(nsAppClass),
           let imp = class_getMethodImplementation(metaclass, NSSelectorFromString("sharedApplication"))
        {
            typealias SharedAppFn = @convention(c) (AnyObject, Selector) -> NSObject
            let sharedApp = unsafeBitCast(imp, to: SharedAppFn.self)(nsAppClass, NSSelectorFromString("sharedApplication"))
            let terminateSel = NSSelectorFromString("terminate:")
            if sharedApp.responds(to: terminateSel) {
                typealias TerminateFn = @convention(c) (NSObject, Selector, AnyObject?) -> Void
                let terminate = unsafeBitCast(sharedApp.method(for: terminateSel), to: TerminateFn.self)
                terminate(sharedApp, terminateSel, nil)
            }
        }
        #endif
    }

    // MARK: - UIApplicationDelegate

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        AppLogger.app.info("HomeClaw starting (unified Catalyst)...")

        // Hide from dock — menu bar only
        #if targetEnvironment(macCatalyst)
        setAccessoryActivationPolicy()
        #endif

        // Initialize HomeKit directly (no IPC needed)
        Task { @MainActor in
            _ = HomeKitManager.shared
            AppLogger.homekit.info("HomeKit manager initialized, waiting for homes...")
        }

        // Start socket server for CLI and MCP clients
        SocketServer.shared.start()

        // Load macOSBridge bundle for the menu bar
        #if targetEnvironment(macCatalyst)
        loadMacOSBridge()
        #endif

        // Observe HomeKit status changes to update the menu bar
        homeKitObserver = NotificationCenter.default.addObserver(
            forName: .homeKitStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let ready = notification.userInfo?["ready"] as? Bool ?? false
            let names = notification.userInfo?["homeNames"] as? [String] ?? []
            MainActor.assumeIsolated {
                self?.macOSController?.updateStatus(ready: ready, homeNames: names)
            }
        }

        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppLogger.app.info("HomeClaw shutting down...")
        SocketServer.shared.stop()
        if let observer = homeKitObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Scene Configuration

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // Settings window — triggered by openSettings() via macOSBridge menu
        if options.userActivities.first?.activityType == "com.shahine.homeclaw.settings" {
            let config = UISceneConfiguration(
                name: "Settings", sessionRole: connectingSceneSession.role)
            config.delegateClass = SettingsSceneDelegate.self
            return config
        }

        // Default scene — hidden (headless Catalyst app)
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = HeadlessSceneDelegate.self
        return config
    }

    // MARK: - macOSBridge Loading

    #if targetEnvironment(macCatalyst)
    private func loadMacOSBridge() {
        // Xcode embeds bundle dependencies in Resources (not PlugIns) for Catalyst apps
        guard let resourcesURL = Bundle.main.resourceURL else {
            AppLogger.app.warning("No Resources directory found")
            return
        }

        let bridgeURL = resourcesURL.appendingPathComponent("macOSBridge.bundle")
        guard let bundle = Bundle(url: bridgeURL) else {
            AppLogger.app.warning("macOSBridge.bundle not found at \(bridgeURL.path)")
            return
        }

        guard bundle.load() else {
            AppLogger.app.error("Failed to load macOSBridge.bundle")
            return
        }

        guard let principalClass = bundle.principalClass as? NSObject.Type else {
            AppLogger.app.error("macOSBridge principal class is not NSObject")
            return
        }

        let instance = principalClass.init()
        guard let controller = instance as? any iOS2Mac else {
            AppLogger.app.error("macOSBridge principal class does not conform to iOS2Mac")
            return
        }

        controller.iOSBridge = self
        macOSController = controller

        AppLogger.app.info("macOSBridge loaded — menu bar active")
    }
    #endif

    // MARK: - Activation Policy

    #if targetEnvironment(macCatalyst)
    /// Sets NSApplication activation policy to .accessory via the ObjC runtime.
    /// This prevents Catalyst from showing any dock icon.
    private func setAccessoryActivationPolicy() {
        guard let nsAppClass: AnyClass = NSClassFromString("NSApplication") else { return }

        let sharedAppSel = NSSelectorFromString("sharedApplication")
        guard let metaclass = object_getClass(nsAppClass),
              let sharedAppIMP = class_getMethodImplementation(metaclass, sharedAppSel)
        else { return }
        typealias SharedAppFn = @convention(c) (AnyObject, Selector) -> NSObject
        let getSharedApp = unsafeBitCast(sharedAppIMP, to: SharedAppFn.self)
        let sharedApp = getSharedApp(nsAppClass, sharedAppSel)

        // 0=regular, 1=accessory, 2=prohibited
        let setPolicySel = NSSelectorFromString("setActivationPolicy:")
        guard sharedApp.responds(to: setPolicySel) else { return }
        typealias SetPolicyFn = @convention(c) (NSObject, Selector, Int) -> Bool
        let setPolicy = unsafeBitCast(sharedApp.method(for: setPolicySel), to: SetPolicyFn.self)
        _ = setPolicy(sharedApp, setPolicySel, 1)

        AppLogger.app.info("Activation policy set to .accessory")
    }
    #endif
}

// MARK: - Settings Scene Delegate

/// Creates a window hosting the SwiftUI SettingsView when triggered by openSettings().
class SettingsSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: SettingsView())
        window.makeKeyAndVisible()
        self.window = window

        #if targetEnvironment(macCatalyst)
        // Single space title suppresses the app name without showing text
        windowScene.title = " "
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 640, height: 720)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 800, height: 900)

        // Bring the app to the foreground and center the window.
        // Two-phase: activate immediately, then center after the window is laid out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Self.activateApp()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Self.centerWindow()
        }
        #endif

        AppLogger.app.info("Settings window opened")
    }

    #if targetEnvironment(macCatalyst)
    /// Temporarily set activation policy to .regular so the settings window is visible,
    /// then revert to .accessory when the scene disconnects.
    private static func activateApp() {
        guard let nsAppClass: AnyClass = NSClassFromString("NSApplication"),
              let metaclass = object_getClass(nsAppClass),
              let imp = class_getMethodImplementation(metaclass, NSSelectorFromString("sharedApplication"))
        else { return }
        typealias SharedAppFn = @convention(c) (AnyObject, Selector) -> NSObject
        let sharedApp = unsafeBitCast(imp, to: SharedAppFn.self)(
            nsAppClass, NSSelectorFromString("sharedApplication"))

        let setPolicySel = NSSelectorFromString("setActivationPolicy:")
        guard sharedApp.responds(to: setPolicySel) else { return }
        typealias SetPolicyFn = @convention(c) (NSObject, Selector, Int) -> Bool
        let setPolicy = unsafeBitCast(sharedApp.method(for: setPolicySel), to: SetPolicyFn.self)
        _ = setPolicy(sharedApp, setPolicySel, 0)  // 0 = regular

        let activateSel = NSSelectorFromString("activateIgnoringOtherApps:")
        if sharedApp.responds(to: activateSel) {
            typealias ActivateFn = @convention(c) (NSObject, Selector, Bool) -> Void
            let activate = unsafeBitCast(sharedApp.method(for: activateSel), to: ActivateFn.self)
            activate(sharedApp, activateSel, true)
        }
    }

    /// Centers the key NSWindow on screen via ObjC runtime.
    private static func centerWindow() {
        guard let nsAppClass: AnyClass = NSClassFromString("NSApplication"),
              let metaclass = object_getClass(nsAppClass),
              let imp = class_getMethodImplementation(metaclass, NSSelectorFromString("sharedApplication"))
        else { return }
        typealias SharedAppFn = @convention(c) (AnyObject, Selector) -> NSObject
        let sharedApp = unsafeBitCast(imp, to: SharedAppFn.self)(
            nsAppClass, NSSelectorFromString("sharedApplication"))

        // Prefer the key window; fall back to the last visible window
        let keyWindowSel = NSSelectorFromString("keyWindow")
        var targetWindow: NSObject?
        if sharedApp.responds(to: keyWindowSel),
           let kw = sharedApp.value(forKey: "keyWindow") as? NSObject {
            targetWindow = kw
        } else if let windows = sharedApp.value(forKey: "windows") as? [NSObject] {
            // Find a visible window (isVisible == true)
            let isVisibleSel = NSSelectorFromString("isVisible")
            targetWindow = windows.last(where: {
                $0.responds(to: isVisibleSel) && ($0.value(forKey: "visible") as? Bool == true)
            }) ?? windows.last
        }

        if let window = targetWindow {
            let centerSel = NSSelectorFromString("center")
            if window.responds(to: centerSel) {
                typealias CenterFn = @convention(c) (NSObject, Selector) -> Void
                let center = unsafeBitCast(window.method(for: centerSel), to: CenterFn.self)
                center(window, centerSel)
            }
        }
    }
    #endif

    func sceneDidDisconnect(_ scene: UIScene) {
        #if targetEnvironment(macCatalyst)
        // Revert to accessory (no dock icon) when settings closes
        guard let nsAppClass: AnyClass = NSClassFromString("NSApplication"),
              let metaclass = object_getClass(nsAppClass),
              let imp = class_getMethodImplementation(metaclass, NSSelectorFromString("sharedApplication"))
        else { return }
        typealias SharedAppFn = @convention(c) (AnyObject, Selector) -> NSObject
        let sharedApp = unsafeBitCast(imp, to: SharedAppFn.self)(
            nsAppClass, NSSelectorFromString("sharedApplication"))

        let setPolicySel = NSSelectorFromString("setActivationPolicy:")
        guard sharedApp.responds(to: setPolicySel) else { return }
        typealias SetPolicyFn = @convention(c) (NSObject, Selector, Int) -> Bool
        let setPolicy = unsafeBitCast(sharedApp.method(for: setPolicySel), to: SetPolicyFn.self)
        _ = setPolicy(sharedApp, setPolicySel, 1)  // 1 = accessory

        AppLogger.app.info("Settings closed — reverted to accessory mode")
        #endif
    }
}

// MARK: - Headless Scene Delegate

/// Keeps the default scene session alive without showing any window.
class HeadlessSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        window = nil

        #if targetEnvironment(macCatalyst)
        if let windowScene = scene as? UIWindowScene {
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 1, height: 1)
            windowScene.sizeRestrictions?.maximumSize = CGSize(width: 1, height: 1)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Self.hideAllNSWindows()
        }
        #endif

        AppLogger.app.info("Default scene connected (headless)")
    }

    #if targetEnvironment(macCatalyst)
    private static func hideAllNSWindows() {
        guard let nsAppClass: AnyClass = NSClassFromString("NSApplication"),
              let metaclass = object_getClass(nsAppClass),
              let imp = class_getMethodImplementation(metaclass, NSSelectorFromString("sharedApplication"))
        else { return }
        typealias SharedAppFn = @convention(c) (AnyObject, Selector) -> NSObject
        let sharedApp = unsafeBitCast(imp, to: SharedAppFn.self)(nsAppClass, NSSelectorFromString("sharedApplication"))

        guard let windows = sharedApp.value(forKey: "windows") as? [NSObject] else { return }

        for nsWindow in windows {
            let setVisibleSel = NSSelectorFromString("setIsVisible:")
            if nsWindow.responds(to: setVisibleSel) {
                typealias SetVisibleFn = @convention(c) (NSObject, Selector, Bool) -> Void
                let setVisible = unsafeBitCast(nsWindow.method(for: setVisibleSel), to: SetVisibleFn.self)
                setVisible(nsWindow, setVisibleSel, false)
            }

            let orderOutSel = NSSelectorFromString("orderOut:")
            if nsWindow.responds(to: orderOutSel) {
                typealias OrderOutFn = @convention(c) (NSObject, Selector, NSObject?) -> Void
                let orderOut = unsafeBitCast(nsWindow.method(for: orderOutSel), to: OrderOutFn.self)
                orderOut(nsWindow, orderOutSel, nil)
            }
        }

        AppLogger.app.info("Hidden \(windows.count) Catalyst NSWindow(s)")
    }
    #endif
}

