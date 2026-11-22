import Foundation
import Combine

/// Counts completed, deliberately selected workflows, not launches, polling or previews.
enum GitHubStarUse {
    case accessoryControl(verified: Bool)
    case sceneExecution
    case webhookDelivery(httpStatus: Int, isTest: Bool)

    var qualifies: Bool {
        switch self {
        case .accessoryControl(let verified): verified
        case .sceneExecution: true
        case .webhookDelivery(let status, let isTest): !isTest && (200..<300).contains(status)
        }
    }

    static func nativeMCP(tool: String, action: String?, result: Any) -> Self? {
        switch (tool, action) {
        case ("homekit_accessories", "control"): return socket(command: "control", result: result)
        case ("homekit_scenes", "trigger"): return .sceneExecution
        default: return nil
        }
    }

    static func socket(command: String, result: Any) -> Self? {
        switch command {
        case "control":
            let fields = result as? [String: Any]
            guard fields?["dry_run"] as? Bool != true else { return nil }
            return .accessoryControl(verified: fields?["verified"] as? Bool == true)
        case "trigger_scene": return .sceneExecution
        default: return nil
        }
    }
}

@MainActor
final class GitHubStarPrompt: ObservableObject {
    static let shared = GitHubStarPrompt(defaults: .standard)
    static let repository = "omarshahine/HomeClaw"
    static let repositoryURL = URL(string: "https://github.com/omarshahine/HomeClaw")!
    static let threshold = 5
    private static let countKey = "githubStarPrompt.useCount"
    private static let consumedKey = "githubStarPrompt.consumed"

    private let defaults: UserDefaults
    private var starRevision = 0
    @Published private(set) var pending: Bool
    @Published private(set) var visible = false
    @Published private(set) var starred = false
    @Published private(set) var requestingStar = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        pending = !defaults.bool(forKey: Self.consumedKey)
            && defaults.integer(forKey: Self.countKey) >= Self.threshold
    }

    func record(_ use: GitHubStarUse) {
        guard use.qualifies, !pending, !defaults.bool(forKey: Self.consumedKey) else { return }
        let count = max(0, defaults.integer(forKey: Self.countKey)) + 1
        defaults.set(min(count, Self.threshold), forKey: Self.countKey)
        pending = count >= Self.threshold
    }

    /// Called only within an active, explicitly opened About window. Persist the
    /// one-time decision before making the note visible; launches never present it.
    func showIfPending() {
        guard pending else { return }
        defaults.set(true, forKey: Self.consumedKey)
        pending = false
        visible = true
    }

    /// Refresh may be superseded by a click; ignore a stale lookup result.
    func refreshStarred(using lookup: @MainActor () async -> Bool?) async {
        guard !requestingStar else { return }
        starRevision += 1
        let revision = starRevision
        guard let result = await lookup(), revision == starRevision, !Task.isCancelled else { return }
        starred = result
        if result {
            defaults.set(true, forKey: Self.consumedKey)
            pending = false
            dismiss()
        }
    }

    func dismiss() {
        visible = false
    }

    /// Local builds may use the existing CLI login, but only after a button press.
    /// App Store callers supply no CLI action and always open the repository.
    func requestStar(
        runCLI: (@MainActor () async -> Bool)?,
        openRepository: @MainActor (URL) -> Void
    ) async {
        guard !requestingStar, !starred else { return }
        starRevision += 1
        defaults.set(true, forKey: Self.consumedKey)
        pending = false
        dismiss()
        requestingStar = true
        defer { requestingStar = false }
        if let runCLI, await runCLI() {
            starred = true
        } else {
            openRepository(Self.repositoryURL)
        }
    }
}
