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
            Tab("Event Log", systemImage: "clock.arrow.circlepath") {
                EventLogSettingsView()
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

// MARK: - Event Log Settings

private struct EventLogSettingsView: View {
    @State private var isEnabled = true
    @State private var maxSizeMB = 50
    @State private var maxBackups = 3
    @State private var stats: EventLogStats?
    @State private var showPurgeConfirm = false
    @State private var webhookEnabled = false
    @State private var webhookURL = ""
    @State private var webhookToken = ""
    @State private var triggers: [HomeClawConfig.WebhookTrigger] = []
    @State private var editingTrigger: HomeClawConfig.WebhookTrigger?
    @State private var showTriggerEditor = false
    @State private var scenes: [SceneInfo] = []
    @State private var accessories: [AccessoryInfo] = []
    @State private var saveTask: Task<Void, Never>?

    struct EventLogStats {
        let fileCount: Int
        let totalSizeMB: String
        let path: String
    }

    struct SceneInfo: Identifiable {
        let id: String
        let name: String
    }

    struct AccessoryInfo: Identifiable {
        let id: String
        let name: String
        let room: String
        let category: String
    }

    private let sizeOptions = [10, 25, 50, 100, 250, 500]

    var body: some View {
        Form {
            Section("Event Logging") {
                Toggle("Enable Event Logging", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, _ in debouncedSave() }

                Picker("Max File Size", selection: $maxSizeMB) {
                    ForEach(sizeOptions, id: \.self) { size in
                        Text("\(size) MB").tag(size)
                    }
                }
                .onChange(of: maxSizeMB) { _, _ in debouncedSave() }

                Stepper("Rotated Backups: \(maxBackups)", value: $maxBackups, in: 0...10)
                    .onChange(of: maxBackups) { _, _ in debouncedSave() }

                Text("Events are logged as JSONL. When the file reaches the size limit, it's rotated. Older backups beyond the count are deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let stats {
                Section("Storage") {
                    LabeledContent("Log Files") {
                        Text("\(stats.fileCount)")
                    }
                    LabeledContent("Total Size") {
                        Text("\(stats.totalSizeMB) MB")
                    }
                    LabeledContent("Location") {
                        Text(stats.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Button("Purge All Events", role: .destructive) {
                        showPurgeConfirm = true
                    }
                    .confirmationDialog("Delete all event logs?", isPresented: $showPurgeConfirm) {
                        Button("Delete All Events", role: .destructive) {
                            Task { @MainActor in
                                HomeEventLogger.shared.purge()
                                await refreshStats()
                            }
                        }
                    } message: {
                        Text("This will permanently delete all recorded HomeKit events. This cannot be undone.")
                    }
                }
            }

            Section("Webhook") {
                Toggle("Enable Webhook", isOn: $webhookEnabled)
                    .onChange(of: webhookEnabled) { _, _ in debouncedSaveWebhook() }

                TextField("URL", text: $webhookURL, prompt: Text("http://127.0.0.1:18789/hooks/wake"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .onChange(of: webhookURL) { _, _ in debouncedSaveWebhook() }

                TextField("Bearer Token", text: $webhookToken, prompt: Text("shared-secret"))
                    .autocorrectionDisabled()
                    .onChange(of: webhookToken) { _, _ in debouncedSaveWebhook() }

                Text("When enabled, all events are POSTed to the URL using the OpenClaw /hooks/wake format.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(triggers) { trigger in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { trigger.enabled },
                            set: { newValue in
                                var updated = trigger
                                updated.enabled = newValue
                                HomeClawConfig.shared.updateWebhookTrigger(updated)
                                triggers = HomeClawConfig.shared.webhookTriggers
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(trigger.label)
                                Text(triggerDescription(trigger))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            editingTrigger = trigger
                            showTriggerEditor = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)

                        Button(role: .destructive) {
                            HomeClawConfig.shared.removeWebhookTrigger(id: trigger.id)
                            triggers = HomeClawConfig.shared.webhookTriggers
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .contextMenu {
                        Button("Edit\u{2026}") {
                            editingTrigger = trigger
                            showTriggerEditor = true
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            HomeClawConfig.shared.removeWebhookTrigger(id: trigger.id)
                            triggers = HomeClawConfig.shared.webhookTriggers
                        }
                    }
                }

                Button("Add Trigger") {
                    editingTrigger = nil
                    showTriggerEditor = true
                }
            } header: {
                Text("Webhook Triggers")
            } footer: {
                Text("Triggers fire a webhook when a specific event occurs. Use HomeKit scenes to group devices (e.g. \"All Lights Off\"), or target individual accessories.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { await loadSettings() }
        .sheet(isPresented: $showTriggerEditor) {
            TriggerEditorSheet(
                trigger: editingTrigger,
                scenes: scenes,
                accessories: accessories
            ) { saved in
                if editingTrigger != nil {
                    HomeClawConfig.shared.updateWebhookTrigger(saved)
                } else {
                    HomeClawConfig.shared.addWebhookTrigger(saved)
                }
                triggers = HomeClawConfig.shared.webhookTriggers
            }
        }
    }

    private func triggerDescription(_ trigger: HomeClawConfig.WebhookTrigger) -> String {
        if let name = trigger.sceneName, !name.isEmpty {
            return "Scene: \(name)"
        }
        var parts: [String] = []
        if let id = trigger.accessoryID, !id.isEmpty {
            let name = accessories.first(where: { $0.id == id })?.name ?? id.prefix(8) + "..."
            parts.append("Device: \(name)")
        }
        if let char = trigger.characteristic, !char.isEmpty {
            let val = trigger.value ?? "any"
            parts.append("\(char) = \(val)")
        }
        return parts.isEmpty ? "No conditions" : parts.joined(separator: ", ")
    }

    @MainActor
    private func loadSettings() async {
        let config = HomeClawConfig.shared
        isEnabled = config.eventLogEnabled
        maxSizeMB = config.eventLogMaxSizeMB
        maxBackups = config.eventLogMaxBackups
        triggers = config.webhookTriggers

        if let webhook = config.webhookConfig {
            webhookEnabled = webhook.enabled
            webhookURL = webhook.url
            webhookToken = webhook.token
        }

        // Load scenes and accessories for the trigger editor
        let hk = HomeKitManager.shared
        let sceneList = await hk.listScenes()
        scenes = sceneList.map { SceneInfo(
            id: $0["id"] as? String ?? UUID().uuidString,
            name: $0["name"] as? String ?? "Unknown"
        )}

        let accList = await hk.listAllAccessories()
        accessories = accList.map { AccessoryInfo(
            id: $0["id"] as? String ?? UUID().uuidString,
            name: $0["name"] as? String ?? "Unknown",
            room: $0["room"] as? String ?? "",
            category: $0["category"] as? String ?? ""
        )}

        await refreshStats()
    }

    @MainActor
    private func refreshStats() async {
        let raw = HomeEventLogger.shared.logStats()
        stats = EventLogStats(
            fileCount: raw["file_count"] as? Int ?? 0,
            totalSizeMB: raw["total_size_mb"] as? String ?? "0.0",
            path: raw["path"] as? String ?? ""
        )
    }

    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let config = HomeClawConfig.shared
            config.eventLogEnabled = isEnabled
            config.eventLogMaxSizeMB = maxSizeMB
            config.eventLogMaxBackups = maxBackups
        }
    }

    private func debouncedSaveWebhook() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            // Preserve existing events filter (only configurable via CLI)
            let existingEvents = HomeClawConfig.shared.webhookConfig?.events
            HomeClawConfig.shared.webhookConfig = HomeClawConfig.WebhookConfig(
                enabled: webhookEnabled,
                url: webhookURL,
                token: webhookToken,
                events: existingEvents
            )
        }
    }
}

// MARK: - Trigger Editor

private struct TriggerEditorSheet: View {
    let trigger: HomeClawConfig.WebhookTrigger?
    let scenes: [EventLogSettingsView.SceneInfo]
    let accessories: [EventLogSettingsView.AccessoryInfo]
    let onSave: (HomeClawConfig.WebhookTrigger) -> Void

    @Environment(\.dismiss) private var dismiss

    enum TriggerKind: String, CaseIterable {
        case scene = "Scene"
        case accessory = "Accessory"
    }

    @State private var label = ""
    @State private var kind: TriggerKind = .scene
    @State private var selectedSceneID = ""
    @State private var selectedAccessoryID = ""
    @State private var characteristic = ""
    @State private var value = ""
    @State private var customMessage = ""

    private let commonCharacteristics = [
        ("power_state", "Power (on/off)"),
        ("lock_target_state", "Lock (locked/unlocked)"),
        ("current_door_state", "Door (open/closed)"),
        ("target_position", "Position (0-100)"),
        ("active", "Active (on/off)"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Trigger") {
                    TextField("Label", text: $label, prompt: Text("e.g. Front door unlocked"))

                    Picker("Type", selection: $kind) {
                        ForEach(TriggerKind.allCases, id: \.self) { k in
                            Text(k.rawValue).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if kind == .scene {
                    Section("Scene") {
                        Picker("Scene", selection: $selectedSceneID) {
                            Text("Select a scene...").tag("")
                            ForEach(scenes) { scene in
                                Text(scene.name).tag(scene.id)
                            }
                        }
                    }
                } else {
                    Section("Accessory") {
                        Picker("Device", selection: $selectedAccessoryID) {
                            Text("Any device").tag("")
                            ForEach(accessories) { acc in
                                let display = acc.room.isEmpty ? acc.name : "\(acc.name) (\(acc.room))"
                                Text(display).tag(acc.id)
                            }
                        }
                    }

                    Section("Condition") {
                        Picker("Characteristic", selection: $characteristic) {
                            Text("Any").tag("")
                            ForEach(commonCharacteristics, id: \.0) { char, desc in
                                Text(desc).tag(char)
                            }
                        }

                        if !characteristic.isEmpty {
                            TextField("Value", text: $value, prompt: Text("e.g. unlocked, off, 0"))
                                .autocorrectionDisabled()
                        }
                    }
                }

                Section("Custom Message (Optional)") {
                    TextField("Message", text: $customMessage, prompt: Text("Auto-generated if empty"))
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(trigger == nil ? "New Trigger" : "Edit Trigger")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(label.isEmpty || !isValid)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 350)
        .onAppear { loadTrigger() }
    }

    private var isValid: Bool {
        switch kind {
        case .scene: return !selectedSceneID.isEmpty
        case .accessory: return !selectedAccessoryID.isEmpty || !characteristic.isEmpty
        }
    }

    private func loadTrigger() {
        guard let t = trigger else { return }
        label = t.label
        customMessage = t.message ?? ""

        if t.sceneName != nil || t.sceneID != nil {
            kind = .scene
            selectedSceneID = t.sceneID ?? ""
            // If matched by name, find the ID
            if selectedSceneID.isEmpty, let name = t.sceneName {
                selectedSceneID = scenes.first(where: {
                    $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                })?.id ?? ""
            }
        } else {
            kind = .accessory
            selectedAccessoryID = t.accessoryID ?? ""
            characteristic = t.characteristic ?? ""
            value = t.value ?? ""
        }
    }

    private func save() {
        var t = trigger ?? HomeClawConfig.WebhookTrigger.create(label: label)
        t.label = label
        t.message = customMessage.isEmpty ? nil : customMessage

        // Clear all match fields first
        t.sceneName = nil
        t.sceneID = nil
        t.accessoryID = nil
        t.accessoryType = nil
        t.characteristic = nil
        t.value = nil

        switch kind {
        case .scene:
            t.sceneID = selectedSceneID
            t.sceneName = scenes.first(where: { $0.id == selectedSceneID })?.name
        case .accessory:
            t.accessoryID = selectedAccessoryID.isEmpty ? nil : selectedAccessoryID
            t.characteristic = characteristic.isEmpty ? nil : characteristic
            t.value = value.isEmpty ? nil : value
        }

        onSave(t)
        dismiss()
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
