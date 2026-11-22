import Foundation
import SwiftUI
import XCTest
@testable import HomeClaw

@MainActor
final class GitHubStarPromptTests: XCTestCase {
    private func withDefaults(_ check: @MainActor (UserDefaults) async throws -> Void) async throws {
        let name = "homeclaw-test-star-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await check(defaults)
    }

    func testFiveQualifiedUsesQueueOnceAcrossRelaunchAndDismissal() async throws {
        try await withDefaults { defaults in
            let prompt = GitHubStarPrompt(defaults: defaults)
            for _ in 0..<4 { prompt.record(.sceneExecution) }
            for _ in 0..<10 {
                prompt.record(.accessoryControl(verified: false))
                prompt.record(.webhookDelivery(httpStatus: 302))
                prompt.record(.webhookDelivery(httpStatus: 500))
            }
            XCTAssertFalse(prompt.pending)
            XCTAssertFalse(prompt.visible)
            prompt.record(.accessoryControl(verified: true))
            XCTAssertTrue(prompt.pending)
            XCTAssertFalse(prompt.visible, "A background action must not open or show Settings")
            let reopened = GitHubStarPrompt(defaults: defaults)
            XCTAssertTrue(reopened.pending)
            reopened.showIfPending()
            XCTAssertTrue(reopened.visible)
            XCTAssertFalse(reopened.pending)
            XCTAssertFalse(GitHubStarPrompt(defaults: defaults).pending, "Already recorded before showing")
            reopened.dismiss()
            for _ in 0..<10 { reopened.record(.webhookDelivery(httpStatus: 204)) }
            reopened.showIfPending()
            XCTAssertFalse(reopened.visible)
        }
    }

    func testSocketClassificationRejectsPollingPreviewsAndUnverifiedWrites() {
        typealias Use = GitHubStarUse
        XCTAssertNil(Use.socket(command: "status", result: [:] as [String: Any]))
        XCTAssertNil(Use.socket(command: "get_accessory", result: [:] as [String: Any]))
        XCTAssertNil(Use.socket(command: "control", result: ["dry_run": true]))
        XCTAssertFalse(Use.socket(command: "control", result: ["verification_skipped": "read_failed"])?.qualifies ?? true)
        XCTAssertTrue(Use.socket(command: "control", result: ["verified": true])?.qualifies ?? false)
        XCTAssertTrue(Use.socket(command: "trigger_scene", result: [:] as [String: Any])?.qualifies ?? false)
    }

    func testExistingLocalStarSuppressesAskAndUnknownRefreshDoesNotEraseIt() async throws {
        try await withDefaults { defaults in
            let prompt = GitHubStarPrompt(defaults: defaults)
            for _ in 0..<5 { prompt.record(.sceneExecution) }
            await prompt.refreshStarred(using: { true })
            prompt.showIfPending()
            XCTAssertTrue(prompt.starred)
            XCTAssertFalse(prompt.visible)
            XCTAssertFalse(GitHubStarPrompt(defaults: defaults).pending)
            await prompt.refreshStarred(using: { nil })
            XCTAssertTrue(prompt.starred)
            await prompt.refreshStarred(using: { false })
            XCTAssertFalse(prompt.starred)
            XCTAssertFalse(prompt.pending)
        }
    }

    func testBrowserOnlyAndLocalCLIFallbackWithoutRealAccount() async throws {
        try await withDefaults { defaults in
            let prompt = GitHubStarPrompt(defaults: defaults)
            var destinations = [URL]()
            await prompt.requestStar(runCLI: nil) { destinations.append($0) }
            XCTAssertEqual(destinations, [GitHubStarPrompt.repositoryURL])
            XCTAssertFalse(prompt.starred, "Opening the browser does not prove the user starred it")
            for _ in 0..<5 { prompt.record(.sceneExecution) }
            XCTAssertFalse(prompt.pending, "An explicit star click suppresses future prompting")

            var processCalls = 0
            await prompt.requestStar(runCLI: { processCalls += 1; return false }) { destinations.append($0) }
            XCTAssertEqual(destinations.count, 2)
            await prompt.requestStar(runCLI: { processCalls += 1; return true }) { destinations.append($0) }
            XCTAssertEqual(processCalls, 2)
            XCTAssertEqual(destinations.count, 2)
            XCTAssertTrue(prompt.starred)
            await prompt.requestStar(runCLI: { XCTFail("Already starred"); return true }) { _ in XCTFail("Unexpected browser open") }
        }
    }

    func testRenderSyntheticAboutNote() throws {
        let renderer = ImageRenderer(content: GitHubStarNote(star: {}, dismiss: {})
            .padding(24)
            .frame(width: 560)
            .background(.background)
            .environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(image.size.height, 80)
        let artifact = XCTAttachment(image: image)
        artifact.name = "HomeClaw GitHub star prompt (synthetic)"
        artifact.lifetime = .keepAlways
        add(artifact)
    }
}
