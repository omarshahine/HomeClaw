import SwiftUI

/// Multi-step onboarding flow shown on first launch.
/// Steps: Welcome → HomeKit → Home Selection (conditional) → Integrations → All Set
///
/// Completion state is tracked via UserDefaults key "isOnboardingCompleted",
/// matching the OnboardingKit convention for future compatibility.
struct OnboardingFlowView: View {
    let onComplete: () -> Void

    @State private var step = 0
    @State private var isLoadingHomes = false
    @State private var homeCount = 0
    @State private var homes: [HomeSelectionView.HomeInfo] = []
    @State private var selectedHomeID = ""

    private struct Feature: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let description: String
    }

    /// Whether the home selection step is included.
    private var hasHomeSelection: Bool {
        homeCount >= 2
    }

    private let features: [Feature] = [
        Feature(
            icon: "menubar.rectangle",
            title: "Interactive Menu Bar",
            description: "Control your accessories directly from the macOS menu bar."
        ),
        Feature(
            icon: "cpu",
            title: "AI Assistant Integration",
            description: "Works with Claude, OpenClaw, and any MCP client."
        ),
        Feature(
            icon: "terminal",
            title: "Command Line Control",
            description: "Full CLI for scripting your smart home."
        ),
        Feature(
            icon: "lock.shield",
            title: "Privacy First",
            description: "All data stays on your Mac. No cloud required."
        ),
    ]

    var body: some View {
        Group {
            switch step {
            case 0:
                welcomeScreen
            case 1:
                HomeKitSetupView {
                    guard !isLoadingHomes else { return }
                    isLoadingHomes = true
                    Task {
                        // Skip for Now must remain immediate when HomeKit isn't ready.
                        if HomeKitManager.shared.isReady { await loadHomes() }
                        step = 2
                        isLoadingHomes = false
                    }
                }
                .allowsHitTesting(!isLoadingHomes)
            case 2 where hasHomeSelection:
                HomeSelectionView(homes: homes, selectedHomeID: $selectedHomeID) {
                    if !selectedHomeID.isEmpty {
                        HomeClawConfig.shared.defaultHomeID = selectedHomeID
                    }
                    step += 1
                }
            case _ where step == (hasHomeSelection ? 3 : 2):
                IntegrationSetupView {
                    step += 1
                }
            default:
                completionScreen
            }
        }
        .animation(.easeInOut(duration: 0.3), value: step)
        .task {
            if UIRegressionEnvironment.enabled,
               ProcessInfo.processInfo.arguments.contains("--ui-test-home-selection") {
                await loadHomes()
                step = 2
            }
        }
    }

    // MARK: - Welcome Screen

    @ViewBuilder
    private var welcomeScreen: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon + title
            VStack(spacing: 8) {
                AppIconView(size: 80)

                VStack(spacing: 2) {
                    Text("Welcome to")
                        .font(.system(size: 36, weight: .semibold))
                    Text("HomeClaw")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.bottom, 36)

            // Feature list
            VStack(alignment: .leading, spacing: 20) {
                ForEach(features) { feature in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: feature.icon)
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .frame(width: 36, height: 36)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(.headline)
                            Text(feature.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: 400)

            Spacer()

            Button {
                step = 1
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 48)
    }

    // MARK: - Completion Screen

    @ViewBuilder
    private var completionScreen: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 12) {
                Text("HomeClaw is Ready")
                    .font(.largeTitle.bold())

                Text("Your smart home is now accessible from the menu bar, CLI, and AI assistants. Look for the HomeClaw icon in your menu bar.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Spacer()

            Button(action: onComplete) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Data Loading

    @MainActor
    private func loadHomes() async {
        let hk = HomeKitManager.shared
        let homesList = await hk.listHomes()
        homes = homesList.map { dict in
            HomeSelectionView.HomeInfo(
                id: dict["id"] as? String ?? UUID().uuidString,
                name: dict["name"] as? String ?? "Unknown",
                accessoryCount: dict["accessory_count"] as? Int ?? 0,
                roomCount: dict["room_count"] as? Int ?? 0
            )
        }

        homeCount = homes.count

        // Pre-select a default that still belongs to the available homes.
        if let defaultID = HomeClawConfig.shared.defaultHomeID, homes.contains(where: { $0.id == defaultID }) {
            selectedHomeID = defaultID
        } else if let first = homes.first {
            selectedHomeID = first.id
        }
    }
}

// MARK: - App Icon View

/// Loads the app icon via the ObjC runtime since NSImage isn't directly
/// available in Mac Catalyst. Falls back to an SF Symbol.
private struct AppIconView: View {
    let size: CGFloat

    var body: some View {
        Group {
            #if targetEnvironment(macCatalyst)
            if let icon = Self.loadAppIcon() {
                Image(uiImage: icon)
                    .resizable()
            } else {
                Image(systemName: "house.fill")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.blue)
            }
            #else
            Image(systemName: "house.fill")
                .font(.system(size: size * 0.6))
                .foregroundStyle(.blue)
            #endif
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .shadow(radius: 4, y: 2)
    }

    #if targetEnvironment(macCatalyst)
    /// Loads the app icon from the bundle's .icns file.
    private static func loadAppIcon() -> UIImage? {
        guard let icnsPath = Bundle.main.path(forResource: "HomeClaw", ofType: "icns"),
              let data = FileManager.default.contents(atPath: icnsPath),
              let image = UIImage(data: data)
        else { return nil }
        return image
    }
    #endif
}

// MARK: - Onboarding Notification

extension Notification.Name {
    /// Posted by OnboardingFlowView when the user completes onboarding.
    /// The OnboardingSceneDelegate observes this to destroy the scene.
    static let onboardingDidComplete = Notification.Name("OnboardingDidComplete")
}
