import XCTest

/// Synthetic, separately identified Debug app; never starts HomeKit or services.
@MainActor
final class OnboardingRegressionTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSevenHomesFullNavigationAndPersistence() throws {
        try verify(count: 7, width: 700, height: 600, fullFlow: true)
    }
    func testTwentyHomesNarrowAndShort() throws {
        try verify(count: 20, width: 466, height: 400)
    }
    func testSevenHomesNarrow() throws { try verify(count: 7, width: 466, height: 600) }
    func testSevenHomesShort() throws { try verify(count: 7, width: 700, height: 400) }
    func testTwoHomes() throws { try verify(count: 2, width: 700, height: 600) }
    func testOneHomeSkipsSelection() throws {
        let app = launch(count: 1, width: 700, height: 600, fixture: UUID(), selection: false)
        defer { app.terminate() }
        advanceToHomes(app)
        XCTAssertTrue(app.staticTexts["Set Up Integrations"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Choose Your Home"].exists)
    }

    func testSkipWhileHomeKitIsUnavailable() throws {
        let app = launch(count: 7, width: 700, height: 600, fixture: UUID(), selection: false, ready: false)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Welcome to"].waitForExistence(timeout: 10))
        app.buttons["Continue"].tap()
        let skip = app.buttons["Skip for Now"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        skip.tap()
        XCTAssertTrue(app.staticTexts["Set Up Integrations"].waitForExistence(timeout: 5))
    }

    private func launch(count: Int, width: Int, height: Int, fixture: UUID, selection: Bool, ready: Bool = true) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.shahine.homeclaw.ui-regression")
        app.launchArguments = ["--ui-test-demo", "--ui-test-isolated"]
        if selection { app.launchArguments.append("--ui-test-home-selection") }
        app.launchEnvironment = ["HOMECLAW_UI_FIXTURE": fixture.uuidString,
            "HOMECLAW_UI_NOT_READY": ready ? "0" : "1",
            "HOMECLAW_UI_HOME_COUNT": String(count), "HOMECLAW_UI_WIDTH": String(width), "HOMECLAW_UI_HEIGHT": String(height)]
        app.launch()
        return app
    }

    private func advanceToHomes(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Welcome to"].waitForExistence(timeout: 10))
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Connected to HomeKit"].waitForExistence(timeout: 10))
        app.buttons["Continue"].tap()
    }

    private func verify(count: Int, width: Int, height: Int, fullFlow: Bool = false) throws {
        let fixture = UUID()
        let app = launch(count: count, width: width, height: height, fixture: fixture, selection: !fullFlow)
        defer { app.terminate() }
        if fullFlow { advanceToHomes(app) }
        let next = app.buttons["onboarding.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        func assertFooter() {
            XCTAssertTrue(next.isHittable)
            XCTAssertTrue(window.frame.contains(next.frame), "Footer must be fully inside the actual Catalyst window: \(window.frame), \(next.frame)")
        }
        assertFooter()
        attach(window, "homes-\(count)-\(width)x\(height)-top")
        let id = String(format: "00000000-0000-4000-8000-%012d", count)
        let last = app.buttons["onboarding.home.\(id)"]
        let scroll = app.scrollViews["onboarding.homes"]
        for _ in 0..<30 {
            if last.exists && last.isHittable { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(last.isHittable)
        last.tap()
        XCTAssertTrue(last.isSelected)
        assertFooter()
        attach(window, "homes-\(count)-\(width)x\(height)-selected")
        next.tap()
        XCTAssertTrue(app.staticTexts["Set Up Integrations"].waitForExistence(timeout: 10))
        if fullFlow {
            app.buttons["Continue"].tap()
            XCTAssertTrue(app.staticTexts["HomeClaw is Ready"].waitForExistence(timeout: 10))
            app.buttons["Get Started"].tap()
        }
        app.terminate()
        app.launchArguments.append("--ui-test-home-selection")
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.continue"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["onboarding.home.\(id)"].isSelected, "Persisted selection must survive relaunch")
        if count > 2 {
            app.terminate()
            app.launchEnvironment["HOMECLAW_UI_HOME_COUNT"] = "2"
            app.launch()
            XCTAssertTrue(app.buttons["onboarding.continue"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["onboarding.home.00000000-0000-4000-8000-000000000001"].isSelected,
                          "A removed default home must fall back to an available home")
        }
    }

    private func attach(_ window: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
