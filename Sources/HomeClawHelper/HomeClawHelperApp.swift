import UIKit

/// Minimal Catalyst app that provides HomeKit access via a Unix domain socket.
/// This is a headless app (no UI) — it runs as a background helper launched by the main app.
///
/// Mac Catalyst requires a scene configuration to keep the process alive.
/// We set the activation policy to .accessory via the ObjC runtime so no
/// window or dock icon is ever shown.
@main
class HomeClawHelperApp: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        HelperLogger.app.info("HomeClaw helper starting...")

        // Hide all UI: no dock icon, no window
        #if targetEnvironment(macCatalyst)
        setAccessoryActivationPolicy()
        #endif

        // Initialize HomeKit on the main actor
        Task { @MainActor in
            _ = HomeKitManager.shared
            HelperLogger.homekit.info("HomeKit manager initialized, waiting for homes...")
        }

        // Start socket server (non-blocking, uses GCD)
        HelperSocketServer.shared.start()

        return true
    }

    // MARK: - Scene Configuration

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = HelperSceneDelegate.self
        return config
    }

    // MARK: - Activation Policy

    #if targetEnvironment(macCatalyst)
    /// Sets NSApplication activation policy to .accessory via the ObjC runtime.
    /// This prevents Catalyst from showing any window or dock icon.
    /// UIKit's `isHidden`/`frame = .zero` don't work on Catalyst because the
    /// bridge always creates a visible NSWindow regardless.
    ///
    /// Uses `class_getMethodImplementation` instead of `perform(_:)` because
    /// Swift 6 strict concurrency introduces multiple ambiguous overloads of
    /// `perform` with different sendability annotations.
    private func setAccessoryActivationPolicy() {
        guard let nsAppClass: AnyClass = NSClassFromString("NSApplication") else { return }

        // Get +[NSApplication sharedApplication] via IMP on the metaclass
        let sharedAppSel = NSSelectorFromString("sharedApplication")
        guard let metaclass = object_getClass(nsAppClass),
              let sharedAppIMP = class_getMethodImplementation(metaclass, sharedAppSel)
        else { return }
        typealias SharedAppFn = @convention(c) (AnyObject, Selector) -> NSObject
        let getSharedApp = unsafeBitCast(sharedAppIMP, to: SharedAppFn.self)
        let sharedApp = getSharedApp(nsAppClass, sharedAppSel)

        // -[NSApplication setActivationPolicy:] takes NSInteger (0=regular, 1=accessory, 2=prohibited)
        let setPolicySel = NSSelectorFromString("setActivationPolicy:")
        guard sharedApp.responds(to: setPolicySel) else { return }
        typealias SetPolicyFn = @convention(c) (NSObject, Selector, Int) -> Bool
        let setPolicy = unsafeBitCast(sharedApp.method(for: setPolicySel), to: SetPolicyFn.self)
        _ = setPolicy(sharedApp, setPolicySel, 1)

        HelperLogger.app.info("Activation policy set to .accessory")
    }
    #endif
}

// MARK: - Scene Delegate

/// Minimal scene delegate — keeps the scene session alive for Catalyst process lifecycle
/// without creating any visible UI.
///
/// Two layers suppress the window: the app delegate sets activation policy to `.accessory`
/// (prevents dock icon and new window activation), and this delegate actively hides any
/// NSWindow that the Catalyst bridge creates during scene setup.
class HelperSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        // Explicitly nil — we don't want a UIWindow
        window = nil

        #if targetEnvironment(macCatalyst)
        // Shrink the scene to minimum size immediately
        if let windowScene = scene as? UIWindowScene {
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 1, height: 1)
            windowScene.sizeRestrictions?.maximumSize = CGSize(width: 1, height: 1)
        }

        // The Catalyst bridge creates the NSWindow asynchronously after this callback
        // completes. A single DispatchQueue.main.async isn't enough — the bridge may
        // take multiple run loop iterations. Use asyncAfter to ensure the window exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Self.hideAllNSWindows()
        }
        #endif

        HelperLogger.app.info("Scene connected (headless)")
    }

    #if targetEnvironment(macCatalyst)
    /// Gets NSApplication.shared via the ObjC runtime (same IMP approach as the app delegate).
    private static func getNSApplication() -> NSObject? {
        guard let nsAppClass: AnyClass = NSClassFromString("NSApplication"),
              let metaclass = object_getClass(nsAppClass),
              let imp = class_getMethodImplementation(metaclass, NSSelectorFromString("sharedApplication"))
        else { return nil }
        typealias SharedAppFn = @convention(c) (AnyObject, Selector) -> NSObject
        return unsafeBitCast(imp, to: SharedAppFn.self)(nsAppClass, NSSelectorFromString("sharedApplication"))
    }

    /// Hides all NSWindows and sets them to not be releasable on close.
    private static func hideAllNSWindows() {
        guard let sharedApp = getNSApplication(),
              let windows = sharedApp.value(forKey: "windows") as? [NSObject]
        else {
            HelperLogger.app.warning("Could not access NSApplication.windows")
            return
        }

        for nsWindow in windows {
            // setIsVisible: false
            let setVisibleSel = NSSelectorFromString("setIsVisible:")
            if nsWindow.responds(to: setVisibleSel) {
                typealias SetVisibleFn = @convention(c) (NSObject, Selector, Bool) -> Void
                let setVisible = unsafeBitCast(nsWindow.method(for: setVisibleSel), to: SetVisibleFn.self)
                setVisible(nsWindow, setVisibleSel, false)
            }

            // orderOut: nil (remove from screen)
            let orderOutSel = NSSelectorFromString("orderOut:")
            if nsWindow.responds(to: orderOutSel) {
                typealias OrderOutFn = @convention(c) (NSObject, Selector, NSObject?) -> Void
                let orderOut = unsafeBitCast(nsWindow.method(for: orderOutSel), to: OrderOutFn.self)
                orderOut(nsWindow, orderOutSel, nil)
            }
        }

        HelperLogger.app.info("Hidden \(windows.count) Catalyst NSWindow(s)")
    }
    #endif
}
