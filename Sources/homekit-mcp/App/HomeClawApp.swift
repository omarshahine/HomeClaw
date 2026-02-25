import SwiftUI

@main
struct HomeClawApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("HomeClaw", systemImage: "house.badge.wifi.fill") {
            MenuBarView()
        }

        Settings {
            SettingsView()
        }
    }
}
