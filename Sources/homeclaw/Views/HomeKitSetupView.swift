import SwiftUI

/// Onboarding screen that shows HomeKit permission/connection status.
/// HomeKit TCC permission is triggered automatically when HMHomeManager
/// accesses homes (already happens on launch). This screen shows the user
/// what's happening and waits for HomeKit to report ready.
struct HomeKitSetupView: View {
    let onContinue: () -> Void

    @State private var isReady = false
    @State private var homeCount = 0
    @State private var statusText = "Connecting to HomeKit\u{2026}"

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "house.badge.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 12) {
                Text("HomeKit Access")
                    .font(.largeTitle.bold())

                Text("HomeClaw needs access to your HomeKit accessories. If you see a permission dialog, tap Allow.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            // Live status indicator
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    if isReady {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.title2)
                    } else {
                        ProgressView()
                            .controlSize(.regular)
                    }

                    Text(statusText)
                        .font(.headline)
                }

                if isReady && homeCount > 0 {
                    Text("Found \(homeCount) home\(homeCount == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: 360)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            Spacer()

            VStack(spacing: 12) {
                Button(action: onContinue) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isReady)

                if !isReady {
                    Button("Skip for Now", action: onContinue)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 40)
        .onAppear(perform: checkCurrentStatus)
        .onReceive(
            NotificationCenter.default.publisher(for: .homeKitStatusDidChange)
        ) { notification in
            let ready = notification.userInfo?["ready"] as? Bool ?? false
            let names = notification.userInfo?["homeNames"] as? [String] ?? []
            updateStatus(ready: ready, homeNames: names)
        }
    }

    private func checkCurrentStatus() {
        Task { @MainActor in
            let hk = HomeKitManager.shared
            isReady = hk.isReady
            homeCount = hk.homes.count
            if isReady {
                statusText = "Connected to HomeKit"
            }
        }
    }

    private func updateStatus(ready: Bool, homeNames: [String]) {
        isReady = ready
        homeCount = homeNames.count
        if ready {
            statusText = "Connected to HomeKit"
        } else {
            statusText = "Connecting to HomeKit\u{2026}"
        }
    }
}
