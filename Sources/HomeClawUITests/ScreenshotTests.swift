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
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        // Give the SwiftUI welcome view time to load fixture data + run
        // any opening animation before capturing.
        sleep(3)
        attachScreenshot(of: window, named: "01_Onboarding")
    }

    /// Settings → main view (HomeKit status, accessory count, default home).
    func test02_SettingsHome() throws {
        let app = launchApp(screen: "settings", onboardingCompleted: true)
        defer { app.terminate() }

        let window = firstVisibleWindow(in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        // SettingsView's `.task` loads homes/rooms/accessories asynchronously.
        sleep(2)
        attachScreenshot(of: window, named: "02_Settings_Home")
    }

    // MARK: - Window selection

    /// Returns the first window with a non-1×1 frame. The headless default
    /// scene shows as a 1×1 hidden window — this filter ensures we capture
    /// the actual Settings or Onboarding window, not that ghost.
    private func firstVisibleWindow(in app: XCUIApplication) -> XCUIElement {
        let windows = app.windows
        // Wait for at least one window to exist before filtering.
        _ = windows.firstMatch.waitForExistence(timeout: 5)
        // XCUIElementQuery is lazy; iterate by index to inspect frames.
        for i in 0..<windows.count {
            let w = windows.element(boundBy: i)
            if w.frame.width > 10, w.frame.height > 10 { return w }
        }
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
