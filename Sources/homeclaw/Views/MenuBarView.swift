import SwiftUI

struct MenuBarView: View {
    private var manager = HelperManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // HomeKit Status
            helperStatusView

            Divider()

            // Restart Helper (visible when in error state)
            if showRestartButton {
                Button {
                    manager.restartHelper()
                } label: {
                    Label(restartButtonLabel, systemImage: "arrow.clockwise")
                }

                Divider()
            }

            SettingsLink {
                Label("Settings...", systemImage: "gear")
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
    }

    // MARK: - Helper Status

    @ViewBuilder
    private var helperStatusView: some View {
        switch manager.state {
        case .starting:
            Label("Starting Helper...", systemImage: "house")
                .foregroundStyle(.secondary)

        case .connected(let homeNames):
            Label(
                homeNames.joined(separator: ", "),
                systemImage: "house.fill"
            )
            .foregroundStyle(.green)

        case .helperDown:
            VStack(alignment: .leading, spacing: 2) {
                Label("Helper Not Running", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                if let diagnostic = manager.launchDiagnostic {
                    Text(diagnostic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if manager.restartsRemaining == 0 {
                    Text("Auto-restart exhausted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .homekitUnavailable(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label("HomeKit Unavailable", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Restart Button

    private var showRestartButton: Bool {
        switch manager.state {
        case .helperDown, .homekitUnavailable:
            return true
        default:
            return false
        }
    }

    private var restartButtonLabel: String {
        let remaining = manager.restartsRemaining
        if remaining < HelperManager.maxAutoRestartsPublic {
            return "Restart Helper (\(remaining) auto-restarts left)"
        }
        return "Restart Helper"
    }
}
