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
    private var menuDataObserver: NSObjectProtocol?
    private var webhookCircuitObserver: NSObjectProtocol?

    /// Set to true only by openSettings() — used to distinguish explicit
    /// settings requests from UIKit scene session restoration on launch.
    static var settingsRequested = false

    /// Weak reference to the settings scene session for reuse.
    static weak var settingsSession: UISceneSession?

    /// Set to true only by openOnboarding() — same gating pattern as settingsRequested.
    static var onboardingRequested = false

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

    @objc func controlAccessory(id: String, characteristic: String, value: String) {
        Task { @MainActor in
            do {
                _ = try await HomeKitManager.shared.controlAccessory(
                    id: id, characteristic: characteristic, value: value)
            } catch {
                AppLogger.app.error("Menu control failed: \(error.localizedDescription)")
                macOSController?.flashError()
            }
        }
    }

    @objc func triggerScene(id: String) {
        Task { @MainActor in
            do {
                _ = try await HomeKitManager.shared.triggerScene(id: id)
            } catch {
                AppLogger.app.error("Menu scene trigger failed: \(error.localizedDescription)")
                macOSController?.flashError()
            }
        }
    }

    @objc func selectHome(id: String) {
        HomeClawConfig.shared.defaultHomeID = id
        HomeKitManager.shared.scheduleMenuDataPush()
        refreshData()
    }

    @objc func openSettings() {
        // Reuse stored session, or search open sessions, or create new
        let existingSession = Self.settingsSession
            ?? UIApplication.shared.openSessions.first { $0.configuration.name == "Settings" }
        Self.settingsRequested = true
        let activity = NSUserActivity(activityType: "com.shahine.homeclaw.settings")
        UIApplication.shared.requestSceneSessionActivation(
            existingSession, userActivity: activity, options: nil)
    }

    func openOnboarding() {
        Self.onboardingRequested = true
        let activity = NSUserActivity(activityType: "com.shahine.homeclaw.onboarding")
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

        // Destroy any restored Settings/Onboarding scene sessions before UIKit
        // connects them — prevents windows from flashing on launch.
        for session in application.openSessions
        where session.configuration.name == "Settings" || session.configuration.name == "Onboarding" {
            application.requestSceneSessionDestruction(session, options: nil)
        }
        #endif

        // HomeKitManager.shared.start() is called from HeadlessSceneDelegate
        // after the first scene connects. Creating HMHomeManager before a
        // window exists causes a TCC privacy violation crash on macOS 26.4+.

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

        // Observe HomeKit menu data changes for the interactive menu
        menuDataObserver = NotificationCenter.default.addObserver(
            forName: .homeKitMenuDataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let data = HomeKitManager.shared.buildMenuData()
                self?.macOSController?.updateMenuData(data)
            }
        }

        // Observe webhook circuit breaker state changes
        webhookCircuitObserver = NotificationCenter.default.addObserver(
            forName: .webhookCircuitStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract state before crossing isolation boundary (Swift 6 strict concurrency)
            let isHardOpen = (notification.userInfo?["state"] as? String) == "hardOpen"
            MainActor.assumeIsolated {
                let data = HomeKitManager.shared.buildMenuData()
                self?.macOSController?.updateMenuData(data)

                // Flash error on hard-open transition
                if isHardOpen {
                    self?.macOSController?.flashError()
                }
            }
        }

        // Show onboarding on first launch — delay slightly to let HomeKit initialize
        #if targetEnvironment(macCatalyst)
        if !UserDefaults.standard.bool(forKey: "isOnboardingCompleted") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openOnboarding()
            }
        }
        #endif

        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppLogger.app.info("HomeClaw shutting down...")
        SocketServer.shared.stop()
        if let observer = homeKitObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = menuDataObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = webhookCircuitObserver {
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

        // Onboarding window — triggered by openOnboarding() on first launch
        if options.userActivities.first?.activityType == "com.shahine.homeclaw.onboarding" {
            let config = UISceneConfiguration(
                name: "Onboarding", sessionRole: connectingSceneSession.role)
            config.delegateClass = OnboardingSceneDelegate.self
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
/// The window is created once and reused — subsequent openSettings() calls just
/// bring it to front without recreating the view hierarchy or re-centering.
class SettingsSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        if HomeClawApp.settingsRequested {
            HomeClawApp.settingsRequested = false
            HomeClawApp.settingsSession = session
            createAndShowWindow(in: windowScene)
        } else {
            // Restored on launch — don't show or store session reference
            // (it may be queued for destruction by didFinishLaunchingWithOptions).
            AppLogger.app.info("Settings scene restored on launch — suppressed")
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        // Called when openSettings() reactivates an existing Settings session.
        guard let windowScene = scene as? UIWindowScene else { return }
        HomeClawApp.settingsRequested = false

        if let window {
            window.isHidden = false
            window.makeKeyAndVisible()
        } else {
            createAndShowWindow(in: windowScene)
        }

        #if targetEnvironment(macCatalyst)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Self.activateApp()
            Self.orderWindowFront()
        }
        #endif
        AppLogger.app.info("Settings window reactivated")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        HomeClawApp.settingsSession = nil
    }

    private func createAndShowWindow(in windowScene: UIWindowScene) {
        let w = UIWindow(windowScene: windowScene)
        w.rootViewController = UIHostingController(rootView: SettingsView())
        w.makeKeyAndVisible()
        self.window = w

        #if targetEnvironment(macCatalyst)
        windowScene.title = " "
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 640, height: 720)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 800, height: 900)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Self.activateApp()
            Self.centerWindow()
        }
        #endif
        AppLogger.app.info("Settings window opened")
    }

    #if targetEnvironment(macCatalyst)
    /// Brings the app to the foreground without changing activation policy.
    /// The app stays in .accessory mode (no dock icon) — windows are still
    /// focusable via activateIgnoringOtherApps.
    private static func activateApp() {
        guard let nsAppClass: AnyClass = NSClassFromString("NSApplication"),
              let metaclass = object_getClass(nsAppClass),
              let imp = class_getMethodImplementation(metaclass, NSSelectorFromString("sharedApplication"))
        else { return }
        typealias SharedAppFn = @convention(c) (AnyObject, Selector) -> NSObject
        let sharedApp = unsafeBitCast(imp, to: SharedAppFn.self)(
            nsAppClass, NSSelectorFromString("sharedApplication"))

        let activateSel = NSSelectorFromString("activateIgnoringOtherApps:")
        if sharedApp.responds(to: activateSel) {
            typealias ActivateFn = @convention(c) (NSObject, Selector, Bool) -> Void
            let activate = unsafeBitCast(sharedApp.method(for: activateSel), to: ActivateFn.self)
            activate(sharedApp, activateSel, true)
        }
    }

    /// Brings the key NSWindow to front without moving it.
    private static func orderWindowFront() {
        guard let window = findKeyWindow() else { return }
        let orderFrontSel = NSSelectorFromString("orderFrontRegardless")
        if window.responds(to: orderFrontSel) {
            typealias OrderFrontFn = @convention(c) (NSObject, Selector) -> Void
            let orderFront = unsafeBitCast(window.method(for: orderFrontSel), to: OrderFrontFn.self)
            orderFront(window, orderFrontSel)
        }
    }

    /// Finds the key NSWindow via ObjC runtime, falling back to last visible window.
    private static func findKeyWindow() -> NSObject? {
        guard let nsAppClass: AnyClass = NSClassFromString("NSApplication"),
              let metaclass = object_getClass(nsAppClass),
              let imp = class_getMethodImplementation(metaclass, NSSelectorFromString("sharedApplication"))
        else { return nil }
        typealias SharedAppFn = @convention(c) (AnyObject, Selector) -> NSObject
        let sharedApp = unsafeBitCast(imp, to: SharedAppFn.self)(
            nsAppClass, NSSelectorFromString("sharedApplication"))

        let keyWindowSel = NSSelectorFromString("keyWindow")
        if sharedApp.responds(to: keyWindowSel),
           let kw = sharedApp.value(forKey: "keyWindow") as? NSObject {
            return kw
        }
        if let windows = sharedApp.value(forKey: "windows") as? [NSObject] {
            let isVisibleSel = NSSelectorFromString("isVisible")
            return windows.last(where: {
                $0.responds(to: isVisibleSel) && ($0.value(forKey: "visible") as? Bool == true)
            }) ?? windows.last
        }
        return nil
    }

    /// Centers the key NSWindow on screen and brings it to front.
    private static func centerWindow() {
        guard let window = findKeyWindow() else { return }

        let centerSel = NSSelectorFromString("center")
        if window.responds(to: centerSel) {
            typealias CenterFn = @convention(c) (NSObject, Selector) -> Void
            let center = unsafeBitCast(window.method(for: centerSel), to: CenterFn.self)
            center(window, centerSel)
        }

        let orderFrontSel = NSSelectorFromString("orderFrontRegardless")
        if window.responds(to: orderFrontSel) {
            typealias OrderFrontFn = @convention(c) (NSObject, Selector) -> Void
            let orderFront = unsafeBitCast(window.method(for: orderFrontSel), to: OrderFrontFn.self)
            orderFront(window, orderFrontSel)
        }
    }
    #endif
}

// MARK: - Onboarding Scene Delegate

/// Creates a window hosting the OnboardingView on first launch.
class OnboardingSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var completionObserver: NSObjectProtocol?

    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard HomeClawApp.onboardingRequested else {
            AppLogger.app.info("Onboarding scene restored on launch — discarding")
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
            return
        }
        HomeClawApp.onboardingRequested = false

        guard let windowScene = scene as? UIWindowScene else { return }

        // Observe completion notification from the SwiftUI view.
        // This decouples the view from UIKit scene lifecycle — the delegate
        // owns the session and handles destruction directly.
        completionObserver = NotificationCenter.default.addObserver(
            forName: .onboardingDidComplete, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                UserDefaults.standard.set(true, forKey: "isOnboardingCompleted")
                AppLogger.app.info("Onboarding completed — closing window")
                // Close the backing NSWindow directly via ObjC runtime.
                // requestSceneSessionDestruction is async and does not reliably
                // dismiss the Catalyst window. Closing the NSWindow triggers
                // sceneDidDisconnect which nils the window reference.
                Self.closeNSKeyWindow()
                self?.completionObserver = nil
            }
        }

        let onboardingView = OnboardingFlowView {
            NotificationCenter.default.post(name: .onboardingDidComplete, object: nil)
        }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: onboardingView)
        window.makeKeyAndVisible()
        self.window = window

        #if targetEnvironment(macCatalyst)
        windowScene.title = "Welcome to HomeClaw"
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 700, height: 600)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 700, height: 600)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Self.activateAndCenter()
        }
        #endif

        AppLogger.app.info("Onboarding window opened")
    }

    #if targetEnvironment(macCatalyst)
    /// Closes the current key NSWindow via the ObjC runtime.
    /// In Catalyst, `requestSceneSessionDestruction` doesn't reliably close
    /// the backing AppKit window. Calling `close` on the NSWindow does,
    /// and triggers `sceneDidEnterBackground` for session cleanup.
    private static func closeNSKeyWindow() {
        guard let nsAppClass: AnyClass = NSClassFromString("NSApplication"),
              let metaclass = object_getClass(nsAppClass),
              let imp = class_getMethodImplementation(metaclass, NSSelectorFromString("sharedApplication"))
        else { return }
        typealias SharedAppFn = @convention(c) (AnyObject, Selector) -> NSObject
        let sharedApp = unsafeBitCast(imp, to: SharedAppFn.self)(
            nsAppClass, NSSelectorFromString("sharedApplication"))

        if let window = sharedApp.value(forKey: "keyWindow") as? NSObject {
            let closeSel = NSSelectorFromString("close")
            if window.responds(to: closeSel) {
                typealias CloseFn = @convention(c) (NSObject, Selector) -> Void
                let close = unsafeBitCast(window.method(for: closeSel), to: CloseFn.self)
                close(window, closeSel)
            }
        }
    }

    private static func activateAndCenter() {
        guard let nsAppClass: AnyClass = NSClassFromString("NSApplication"),
              let metaclass = object_getClass(nsAppClass),
              let imp = class_getMethodImplementation(metaclass, NSSelectorFromString("sharedApplication"))
        else { return }
        typealias SharedAppFn = @convention(c) (AnyObject, Selector) -> NSObject
        let sharedApp = unsafeBitCast(imp, to: SharedAppFn.self)(
            nsAppClass, NSSelectorFromString("sharedApplication"))

        // Activate
        let activateSel = NSSelectorFromString("activateIgnoringOtherApps:")
        if sharedApp.responds(to: activateSel) {
            typealias ActivateFn = @convention(c) (NSObject, Selector, Bool) -> Void
            let activate = unsafeBitCast(sharedApp.method(for: activateSel), to: ActivateFn.self)
            activate(sharedApp, activateSel, true)
        }

        // Center the key window
        if let window = sharedApp.value(forKey: "keyWindow") as? NSObject {
            let centerSel = NSSelectorFromString("center")
            if window.responds(to: centerSel) {
                typealias CenterFn = @convention(c) (NSObject, Selector) -> Void
                let center = unsafeBitCast(window.method(for: centerSel), to: CenterFn.self)
                center(window, centerSel)
            }

            let orderFrontSel = NSSelectorFromString("orderFrontRegardless")
            if window.responds(to: orderFrontSel) {
                typealias OrderFrontFn = @convention(c) (NSObject, Selector) -> Void
                let orderFront = unsafeBitCast(window.method(for: orderFrontSel), to: OrderFrontFn.self)
                orderFront(window, orderFrontSel)
            }
        }
    }
    #endif

    func sceneDidDisconnect(_ scene: UIScene) {
        #if targetEnvironment(macCatalyst)
        AppLogger.app.info("Onboarding scene disconnected")
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

        // Start HomeKit now that a scene exists to host the TCC consent dialog.
        // Creating HMHomeManager before this point crashes on macOS 26.4+ with
        // __TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__.
        HomeKitManager.shared.start()
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

