import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("HomeKit", systemImage: "house") {
                HomeKitSettingsView()
            }
            Tab("Devices", systemImage: "list.bullet.rectangle") {
                DeviceFilterSettingsView()
            }
            Tab("Integrations", systemImage: "puzzlepiece") {
                #if APP_STORE
                AppStoreIntegrationsView()
                #else
                IntegrationsSettingsView()
                #endif
            }
        }
    }
}

// MARK: - HomeKit

private struct HomeKitSettingsView: View {
    @State private var isReady = false
    @State private var homeCount = 0
    @State private var accessoryCount = 0
    @State private var homes: [HomeInfo] = []
    @State private var selectedDefaultHome: String = ""
    @State private var isLoaded = false

    struct HomeInfo: Identifiable {
        let id: String
        let name: String
        let accessoryCount: Int
        let roomCount: Int
    }

    var body: some View {
        Form {
            if isLoaded {
                LabeledContent("Status") {
                    Label(
                        isReady ? "Connected" : "Waiting...",
                        systemImage: isReady ? "checkmark.circle.fill" : "circle.dotted"
                    )
                    .foregroundStyle(isReady ? .green : .secondary)
                }

                LabeledContent("Homes") {
                    Text("\(homeCount)")
                }

                LabeledContent("Total Accessories") {
                    Text("\(accessoryCount)")
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
                            HomeClawConfig.shared.defaultHomeID = newValue
                        }

                        Text("All commands operate on the selected home.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                LabeledContent("Status") {
                    Label("Loading...", systemImage: "circle.dotted")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .task { await loadStatus() }
    }

    @MainActor
    private func loadStatus() async {
        let hk = HomeKitManager.shared
        isReady = hk.isReady
        homeCount = hk.homes.count
        accessoryCount = hk.totalAccessoryCount

        let homesList = await hk.listHomes()
        homes = homesList.map { dict in
            HomeInfo(
                id: dict["id"] as? String ?? UUID().uuidString,
                name: dict["name"] as? String ?? "Unknown",
                accessoryCount: dict["accessory_count"] as? Int ?? 0,
                roomCount: dict["room_count"] as? Int ?? 0
            )
        }

        // Load current default home config
        if let defaultID = HomeClawConfig.shared.defaultHomeID, !defaultID.isEmpty {
            selectedDefaultHome = defaultID
        } else if !homes.isEmpty {
            selectedDefaultHome = homes[0].id
            HomeClawConfig.shared.defaultHomeID = selectedDefaultHome
        }

        isLoaded = true
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

    private var homeNames: [String] {
        Array(Set(allAccessories.map(\.homeName))).sorted()
    }

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
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 6)

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
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
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
                .padding(6)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

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
                                .toggleStyle(.automatic)
                                .foregroundStyle(someChecked && !allChecked ? .secondary : .primary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
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
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
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
        .toggleStyle(.automatic)
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
            HomeClawConfig.shared.filterMode = filterMode
            HomeClawConfig.shared.setAllowedAccessories(ids)
        }
    }

    // MARK: - Data Loading

    @MainActor
    private func loadAccessories() async {
        defer { isLoading = false }

        let arr = await HomeKitManager.shared.listAllAccessories()

        let currentMode = HomeClawConfig.shared.filterMode
        let allowedIDs: Set<String>
        if let ids = HomeClawConfig.shared.allowedIDs {
            allowedIDs = ids
        } else {
            allowedIDs = []
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
    }
}

// MARK: - App Store Integrations (sandbox-safe, copy-only)

#if APP_STORE
private struct AppStoreIntegrationsView: View {
    @State private var copied: String?

    private static let githubRepo = "omarshahine/HomeClaw"

    private static var bundledCLIPath: String {
        "/Applications/HomeClaw.app/Contents/MacOS/homeclaw-cli"
    }

    private static var homebrewBinDir: String {
        #if arch(arm64)
        return "/opt/homebrew/bin"
        #else
        return "/usr/local/bin"
        #endif
    }

    var body: some View {
        Form {
            // CLI
            Section("Command Line") {
                LabeledContent("Binary") {
                    Text(Self.bundledCLIPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button("Copy Symlink Command") {
                    let cmd = "ln -sf '\(Self.bundledCLIPath)' '\(Self.homebrewBinDir)/homeclaw-cli'"
                    copyToClipboard(cmd, label: "CLI")
                }

                Text("Run this command in Terminal to add homeclaw-cli to your PATH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Claude Desktop
            Section("Claude Desktop") {
                Button("Copy MCP Config") {
                    let serverJS = "/Applications/HomeClaw.app/Contents/Resources/mcp-server.js"
                    let config = """
                        {
                          "mcpServers": {
                            "homeclaw": {
                              "command": "node",
                              "args": ["\(serverJS)"]
                            }
                          }
                        }
                        """
                    copyToClipboard(config, label: "Claude Desktop")
                }

                Text("Paste into ~/Library/Application Support/Claude/claude_desktop_config.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Claude Code
            Section("Claude Code") {
                Button("Copy Install Commands") {
                    let commands = """
                        /plugin marketplace add \(Self.githubRepo)
                        /plugin install homeclaw@homeclaw
                        """
                    copyToClipboard(commands, label: "Claude Code")
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Run these commands in Claude Code:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("/plugin marketplace add \(Self.githubRepo)")
                    Text("/plugin install homeclaw@homeclaw")
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            // OpenClaw
            Section("OpenClaw") {
                Button("Copy Setup Commands") {
                    let instructions = """
                        openclaw plugins install "/Applications/HomeClaw.app/Contents/Resources/openclaw"
                        openclaw plugins enable homeclaw
                        ln -sf '\(Self.bundledCLIPath)' '\(Self.homebrewBinDir)/homeclaw-cli'
                        openclaw gateway restart
                        """
                    copyToClipboard(instructions, label: "OpenClaw")
                }

                Text("Run these commands to install the HomeClaw plugin in OpenClaw.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let copied {
                Section {
                    Label("\(copied) config copied to clipboard", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section {
                Text("Integration setup requires running commands in Terminal or the target app. The CLI, MCP server, and OpenClaw plugin are bundled inside the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func copyToClipboard(_ text: String, label: String) {
        #if targetEnvironment(macCatalyst)
        UIPasteboard.general.string = text
        #endif
        copied = label
        Task {
            try? await Task.sleep(for: .seconds(3))
            if copied == label { copied = nil }
        }
    }
}
#endif
