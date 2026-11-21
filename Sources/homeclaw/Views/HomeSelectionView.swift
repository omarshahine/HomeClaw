import SwiftUI

/// Keeps navigation visible even when the available homes exceed the welcome window.
struct HomeSelectionView: View {
    struct HomeInfo: Identifiable {
        let id: String
        let name: String
        let accessoryCount: Int
        let roomCount: Int
    }

    let homes: [HomeInfo]
    @Binding var selectedHomeID: String
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 32) {
                    HomeSelectionHeader()

                    VStack(spacing: 8) {
                        ForEach(homes) { home in
                            HomeSelectionRow(
                                home: home,
                                isSelected: selectedHomeID == home.id
                            ) {
                                selectedHomeID = home.id
                            }
                        }
                    }
                    .frame(maxWidth: 440)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 32)
                .padding(.bottom, 24)
            }
            .accessibilityIdentifier("onboarding.homes")

            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedHomeID.isEmpty)
            .accessibilityIdentifier("onboarding.continue")
            .padding(.horizontal, 40)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
    }
}

private struct HomeSelectionHeader: View {
    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: "house.2.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 12) {
                Text("Choose Your Home")
                    .font(.largeTitle.bold())

                Text("You have multiple HomeKit homes. Select the one HomeClaw should use by default.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        }
    }
}

private struct HomeSelectionRow: View {
    let home: HomeSelectionView.HomeInfo
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(home.name)
                        .font(.headline)
                    Text("\(home.accessoryCount) accessories, \(home.roomCount) rooms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.blue) : AnyShapeStyle(.tertiary))
                    .font(.title3)
            }
            .padding()
            .background(
                isSelected ? Color.blue.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding.home.\(home.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
