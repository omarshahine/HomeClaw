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

    /// Onboarding: first-launch welcome flow. Demo mode auto-opens the
    /// onboarding window when launched with `--ui-test-screen onboarding`.
    func test01_Onboarding() throws {
        let app = launchApp(screen: "onboarding", onboardingCompleted: false)
        defer { app.terminate() }

        // Onboarding window appears ~0.5s after launch (see HomeClawApp).
        let onboardingWindow = app.windows.firstMatch
        XCTAssertTrue(onboardingWindow.waitForExistence(timeout: 5))

        sleep(1)  // Let the SwiftUI view settle (animations, fixture data load)
        attachScreenshot(named: "01-Onboarding")
    }

    /// Settings → main view (HomeKit status, accessory count, default home).
    func test02_SettingsHome() throws {
        let app = launchApp(screen: "settings", onboardingCompleted: true)
        defer { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        sleep(2)  // SwiftUI Settings does an async .task to load homes/accessories
        attachScreenshot(named: "02-Settings-Home")
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

    /// Attach the current screen capture as an XCTAttachment. Lifetime is
    /// `keepAlways` so the .xcresult bundle retains it for `xcparse` to
    /// extract after the test run.
    @MainActor
    private func attachScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
