import XCTest

/// Captures App Store screenshots of HomeClaw running in demo mode (synthetic
/// HomeKit data — no real user homes are ever touched). One screenshot per
/// test method; fastlane's `screenshots` lane runs `xcparse` to extract them.
///
/// Demo mode is enabled via the `--ui-test-demo` launch arg, which causes
/// `HomeKitManager` to short-circuit `HMHomeManager` and serve `DemoFixtures`
/// data. See `Sources/homeclaw/HomeKit/DemoFixtures.swift`.
@MainActor
final class ScreenshotTests: XCTestCase {

    /// Headless default scene shows as a 1×1 hidden window. Anything larger
    /// than this is the real Settings/Onboarding window — see
    /// `firstVisibleWindow`.
    private static let ghostWindowMaxDimension: CGFloat = 100

    override class var runsForEachTargetApplicationUIConfiguration: Bool { false }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Onboarding: first-launch welcome flow. We always pass
    /// `onboardingCompleted: true` so HomeClawApp's auto-open path stays
    /// dormant — `--ui-test-screen onboarding` is the only trigger, so we
    /// avoid double-activating the scene (which produced a blank window
    /// in the first run).
    func test01_Onboarding() throws {
        let app = launchApp(screen: "onboarding", onboardingCompleted: true)
        defer { app.terminate() }

        let window = firstVisibleWindow(in: app)
        // Wait for the Continue button to exist as a signal that the SwiftUI
        // welcome view has fully loaded. Falls back to a brief sleep for the
        // opening animation if accessibility isn't yet plumbed.
        _ = app.buttons["Continue"].waitForExistence(timeout: 10)
        sleep(1)
        attachScreenshot(of: window, named: "01_Onboarding")
    }

    /// Settings → main view (HomeKit status, accessory count, default home).
    func test02_SettingsHome() throws {
        let app = launchApp(screen: "settings", onboardingCompleted: true)
        defer { app.terminate() }

        let window = firstVisibleWindow(in: app)
        // "Demo Home" rendering means SettingsView's `.task` finished its
        // async listHomes() round-trip — much more robust than a fixed sleep.
        _ = app.staticTexts["Demo Home"].waitForExistence(timeout: 10)
        sleep(1)
        attachScreenshot(of: window, named: "02_Settings_Home")
    }

    // MARK: - Window selection

    /// Returns the first window with a non-ghost frame. Polls up to 10s for
    /// a real window to appear in the accessibility tree — without this, on
    /// a cold launch the SwiftUI window may not be registered yet and we'd
    /// fall through to capturing the 1×1 ghost (producing a useless
    /// screenshot). Calls `XCTFail` on timeout rather than silently returning
    /// the ghost; with `continueAfterFailure = false` the test then stops.
    private func firstVisibleWindow(in app: XCUIApplication) -> XCUIElement {
        let windows = app.windows
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            for i in 0..<windows.count {
                let w = windows.element(boundBy: i)
                if w.exists,
                   w.frame.width > Self.ghostWindowMaxDimension,
                   w.frame.height > Self.ghostWindowMaxDimension {
                    return w
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("No visible window appeared within 10s — only the 1×1 headless scene is in the accessibility tree.")
        return windows.firstMatch
    }

    // MARK: - Helpers

    private func launchApp(screen: String, onboardingCompleted: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-demo",
            "--ui-test-screen", screen,
            // UIKit/AppKit interpret -KeyName YES at launch as a UserDefaults override.
            "-isOnboardingCompleted", onboardingCompleted ? "YES" : "NO",
        ]
        app.launchEnvironment = ["HOMECLAW_DEMO": "1"]
        app.launch()
        return app
    }

    /// Attach a screenshot of the given element (typically a window) as an
    /// XCTAttachment. We capture the element rather than `XCUIScreen.main`
    /// so the surrounding desktop, menu bar, and other apps never appear in
    /// the App Store screenshot. Lifetime `.keepAlways` so the .xcresult
    /// bundle retains it for `xcparse` extraction.
    @MainActor
    private func attachScreenshot(of element: XCUIElement, named name: String) {
        let screenshot = element.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
