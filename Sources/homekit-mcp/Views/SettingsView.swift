import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gear") {
                GeneralSettingsView()
            }
            Tab("HomeKit", systemImage: "house") {
                HomeKitSettingsView()
            }
            Tab("Devices", systemImage: "list.bullet.rectangle") {
                DeviceFilterSettingsView()
            }
            Tab("Integrations", systemImage: "puzzlepiece") {
                IntegrationsSettingsView()
            }
        }
        .frame(width: 550, height: 550)
        .onAppear {
            // Menu bar apps (.accessory policy) don't auto-focus new windows.
            // Find our settings window and bring it to front.
            DispatchQueue.main.async {
                for window in NSApp.windows where window.isVisible && window.canBecomeKey {
                    window.makeKeyAndOrderFront(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage(AppConfig.launchAtLoginKey) private var launchAtLogin = false

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        AppLogger.app.error("Launch at login toggle failed: \(error.localizedDescription)")
                    }
                }

            Text("HomeClaw v\(AppConfig.version) (\(AppConfig.build))")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .formStyle(.grouped)
    }
}

// MARK: - HomeKit

private struct HomeKitSettingsView: View {
    @State private var status: HomeKitClient.Status?
    @State private var homes: [HomeInfo] = []
    @State private var errorMessage: String?
    @State private var selectedDefaultHome: String = ""

    struct HomeInfo: Identifiable {
        let id: String
        let name: String
        let accessoryCount: Int
        let roomCount: Int
    }

    var body: some View {
        Form {
            if let status {
                LabeledContent("Status") {
                    Label(
                        status.ready ? "Connected" : "Waiting...",
                        systemImage: status.ready ? "checkmark.circle.fill" : "circle.dotted"
                    )
                    .foregroundStyle(status.ready ? .green : .secondary)
                }

                LabeledContent("Homes") {
                    Text("\(status.homeCount)")
                }

                LabeledContent("Total Accessories") {
                    Text("\(status.accessoryCount)")
                }

                if !homes.isEmpty {
                    Section("Homes") {
                        ForEach(homes) { home in
                            LabeledContent(home.name) {
                                Text("\(home.accessoryCount) accessories, \(home.roomCount) rooms")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("Active Home") {
                        Picker("Active Home", selection: $selectedDefaultHome) {
                            ForEach(homes) { home in
                                Text(home.name).tag(home.id)
                            }
                        }
                        .onChange(of: selectedDefaultHome) { _, newValue in
                            guard !newValue.isEmpty else { return }
                            Task {
                                _ = try? await HomeKitClient.shared.setConfig(defaultHomeID: newValue)
                            }
                        }

                        Text("All commands operate on the selected home. Use the CLI to switch homes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let errorMessage {
                LabeledContent("Status") {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } else {
                LabeledContent("Status") {
                    Label("Loading...", systemImage: "circle.dotted")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await loadStatus() }
    }

    private func loadStatus() async {
        do {
            status = try await HomeKitClient.shared.status()
            let data = try await HomeKitClient.shared.listHomes()
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                homes = arr.map { dict in
                    HomeInfo(
                        id: dict["id"] as? String ?? UUID().uuidString,
                        name: dict["name"] as? String ?? "Unknown",
                        accessoryCount: dict["accessory_count"] as? Int ?? 0,
                        roomCount: dict["room_count"] as? Int ?? 0
                    )
                }
            }

            // Load current default home config
            let configData = try await HomeKitClient.shared.getConfig()
            if let configDict = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
               let config = configDict["config"] as? [String: Any],
               let defaultID = config["default_home_id"] as? String,
               !defaultID.isEmpty
            {
                selectedDefaultHome = defaultID
            } else if !homes.isEmpty {
                // No default configured — auto-select first home and persist it
                selectedDefaultHome = homes[0].id
                _ = try? await HomeKitClient.shared.setConfig(defaultHomeID: selectedDefaultHome)
            }
        } catch {
            errorMessage = "Helper not running"
        }
    }
}

// MARK: - Device Filtering

private struct DeviceFilterSettingsView: View {
    @State private var filterMode = "all"
    @State private var allAccessories: [AccessoryItem] = []
    @State private var selectedHome = ""
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var saveTask: Task<Void, Never>?

    struct AccessoryItem: Identifiable {
        let id: String
        let name: String
        let category: String
        let room: String
        let homeName: String
        var isAllowed: Bool
    }

    /// All unique home names derived from loaded accessories.
    private var homeNames: [String] {
        Array(Set(allAccessories.map(\.homeName))).sorted()
    }

    /// Accessories scoped to the selected home.
    private var accessories: [AccessoryItem] {
        allAccessories.filter { $0.homeName == selectedHome }
    }

    private var filteredAccessories: [AccessoryItem] {
        guard !searchText.isEmpty else { return accessories }
        let query = searchText.lowercased()
        return accessories.filter {
            $0.name.lowercased().contains(query)
                || $0.room.lowercased().contains(query)
                || $0.category.lowercased().contains(query)
        }
    }

    private var groupedByRoom: [(room: String, items: [AccessoryItem])] {
        let grouped = Dictionary(grouping: filteredAccessories) { $0.room.isEmpty ? "No Room" : $0.room }
        return grouped.sorted { $0.key < $1.key }.map { (room: $0.key, items: $0.value) }
    }

    /// Allowed count scoped to the selected home (for the footer display).
    private var allowedCountInHome: Int {
        accessories.filter(\.isAllowed).count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter mode picker
            HStack {
                Text("Filter Mode:")
                    .font(.headline)
                Picker("", selection: $filterMode) {
                    Text("All Accessories").tag("all")
                    Text("Selected Only").tag("allowlist")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .onChange(of: filterMode) { _, _ in
                    debouncedSave()
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Home selector
            if homeNames.count > 1 {
                HStack {
                    Text("Home:")
                        .font(.headline)
                    Picker("", selection: $selectedHome) {
                        ForEach(homeNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .frame(maxWidth: 250)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            if isLoading {
                Spacer()
                ProgressView("Loading accessories...")
                Spacer()
            } else if let errorMessage {
                Spacer()
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Spacer()
            } else {
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search by name, room, or category...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
                .padding(.bottom, 8)

                // Accessory list grouped by room
                List {
                    ForEach(groupedByRoom, id: \.room) { group in
                        Section {
                            ForEach(group.items) { item in
                                accessoryRow(item)
                            }
                        } header: {
                            HStack {
                                let allChecked = group.items.allSatisfy(\.isAllowed)
                                let someChecked = group.items.contains(where: \.isAllowed)
                                Toggle(isOn: Binding(
                                    get: { allChecked },
                                    set: { newValue in
                                        toggleRoom(group.room, isOn: newValue)
                                    }
                                )) {
                                    Text(group.room)
                                        .font(.headline)
                                }
                                .toggleStyle(.checkbox)
                                .foregroundStyle(someChecked && !allChecked ? .secondary : .primary)
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .disabled(filterMode == "all")
                .opacity(filterMode == "all" ? 0.5 : 1.0)

                // Bottom toolbar
                HStack {
                    Button("Select All") { setAll(true) }
                        .disabled(filterMode == "all")
                    Button("Deselect All") { setAll(false) }
                        .disabled(filterMode == "all")
                    Spacer()
                    Text("\(allowedCountInHome) of \(accessories.count) accessories exposed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .task { await loadAccessories() }
    }

    @ViewBuilder
    private func accessoryRow(_ item: AccessoryItem) -> some View {
        let binding = Binding(
            get: { item.isAllowed },
            set: { newValue in
                toggleAccessory(id: item.id, isOn: newValue)
            }
        )
        Toggle(isOn: binding) {
            HStack {
                Text(item.name)
                Spacer()
                Text(item.category)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .toggleStyle(.checkbox)
    }

    // MARK: - Actions

    private func toggleAccessory(id: String, isOn: Bool) {
        guard let idx = allAccessories.firstIndex(where: { $0.id == id }) else { return }
        allAccessories[idx].isAllowed = isOn
        debouncedSave()
    }

    private func toggleRoom(_ room: String, isOn: Bool) {
        let homeAccessoryIDs = Set(accessories.filter {
            ($0.room.isEmpty ? "No Room" : $0.room) == room
        }.map(\.id))
        for idx in allAccessories.indices where homeAccessoryIDs.contains(allAccessories[idx].id) {
            allAccessories[idx].isAllowed = isOn
        }
        debouncedSave()
    }

    private func setAll(_ value: Bool) {
        let homeAccessoryIDs = Set(accessories.map(\.id))
        for idx in allAccessories.indices where homeAccessoryIDs.contains(allAccessories[idx].id) {
            allAccessories[idx].isAllowed = value
        }
        debouncedSave()
    }

    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let ids = allAccessories.filter(\.isAllowed).map(\.id)
            _ = try? await HomeKitClient.shared.setConfig(
                filterMode: filterMode,
                allowedAccessoryIDs: ids
            )
        }
    }

    // MARK: - Data Loading

    private func loadAccessories() async {
        defer { isLoading = false }
        do {
            // Load all accessories (unfiltered)
            let data = try await HomeKitClient.shared.listAllAccessories()
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                errorMessage = "Invalid response"
                return
            }

            // Load current config to know which are allowed
            let configData = try await HomeKitClient.shared.getConfig()
            var currentMode = "all"
            var allowedIDs: Set<String> = []
            if let configDict = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
               let config = configDict["config"] as? [String: Any]
            {
                currentMode = config["accessory_filter_mode"] as? String ?? "all"
                if let ids = config["allowed_accessory_ids"] as? [String] {
                    allowedIDs = Set(ids)
                }
            }

            filterMode = currentMode
            allAccessories = arr.map { dict in
                let id = dict["id"] as? String ?? UUID().uuidString
                return AccessoryItem(
                    id: id,
                    name: dict["name"] as? String ?? "Unknown",
                    category: dict["category"] as? String ?? "Other",
                    room: dict["room"] as? String ?? "",
                    homeName: dict["home_name"] as? String ?? "",
                    isAllowed: allowedIDs.isEmpty || allowedIDs.contains(id)
                )
            }

            // Default to first home
            if selectedHome.isEmpty, let firstName = homeNames.first {
                selectedHome = firstName
            }
        } catch {
            errorMessage = "Helper not running"
        }
    }
}
