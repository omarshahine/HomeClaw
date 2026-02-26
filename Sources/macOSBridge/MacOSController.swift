import AppKit

/// AppKit-based menu bar controller loaded as a plugin bundle from the Catalyst app.
/// Conforms to `iOS2Mac` protocol so the Catalyst host can push HomeKit status and
/// interactive menu data.
///
/// The menu displays rooms, accessories, and scenes for direct control from the
/// menu bar. Accessories are classified as toggleable (lights, switches, fans) or
/// status-only (thermostats, locks, sensors), with appropriate SF Symbols and actions.
@objc(MacOSController)
public class MacOSController: NSObject, iOS2Mac, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    @objc public var iOSBridge: (any Mac2iOS)?

    private var currentReady = false
    private var currentHomeNames: [String] = []
    private var menuData: [String: Any]?

    private var menuIsOpen = false
    private var pendingMenuData: [String: Any]?
    private var originalStatusImage: NSImage?
    private var errorRestoreWorkItem: DispatchWorkItem?

    public override required init() {
        super.init()
        setupStatusItem()
    }

    // MARK: - iOS2Mac Protocol

    public func updateStatus(ready: Bool, homeNames: [String]) {
        currentReady = ready
        currentHomeNames = homeNames
        // Only rebuild from status if we don't have full menu data yet
        if menuData == nil {
            rebuildMenu()
        }
    }

    public func updateMenuData(_ data: [String: Any]) {
        if menuIsOpen {
            pendingMenuData = data
        } else {
            menuData = data
            rebuildMenu()
        }
    }

    public func showError(message: String) {
        currentReady = false
        currentHomeNames = []
        menuData = nil
        rebuildMenu()
    }

    public func flashError() {
        guard let button = statusItem?.button else { return }

        // Only capture the original icon if not already flashing
        if originalStatusImage == nil {
            originalStatusImage = button.image
        }

        button.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Error")

        // Cancel any pending restoration and schedule a new one
        errorRestoreWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak button] in
            button?.image = self?.originalStatusImage
            self?.originalStatusImage = nil
        }
        errorRestoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    // MARK: - NSMenuDelegate

    public func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        iOSBridge?.refreshData()
    }

    public func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if let pending = pendingMenuData {
            pendingMenuData = nil
            menuData = pending
            rebuildMenu()
        }
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        // Use variableLength — squareLength doesn't render correctly in Mac Catalyst's AppKit bridge
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "house.badge.wifi.fill",
                accessibilityDescription: "HomeClaw")
        }

        item.isVisible = true
        menu = NSMenu()
        menu?.autoenablesItems = false
        menu?.delegate = self
        item.menu = menu
        rebuildMenu()
    }

    // MARK: - Menu Building

    private func rebuildMenu() {
        guard let menu else { return }
        menu.removeAllItems()

        // Use full menu data if available, otherwise show basic status
        if let menuData, menuData["ready"] as? Bool == true {
            buildInteractiveMenu(from: menuData, into: menu)
        } else if currentReady {
            let statusText = currentHomeNames.isEmpty
                ? "Connected"
                : currentHomeNames.joined(separator: ", ")
            let item = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil)
            menu.addItem(item)
        } else {
            let item = NSMenuItem(
                title: "Waiting for HomeKit\u{2026}", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "house", accessibilityDescription: nil)
            menu.addItem(item)
        }

        addStandardItems(to: menu)
    }

    private func buildInteractiveMenu(from data: [String: Any], into menu: NSMenu) {
        let homes = data["homes"] as? [[String: Any]] ?? []
        let selectedHome = data["selected_home"] as? String ?? "Home"
        let scenes = data["scenes"] as? [[String: Any]] ?? []
        let rooms = data["rooms"] as? [[String: Any]] ?? []

        // Home name or multi-home picker
        if homes.count > 1 {
            let homeItem = NSMenuItem(title: selectedHome, action: nil, keyEquivalent: "")
            homeItem.image = NSImage(
                systemSymbolName: "house.fill", accessibilityDescription: nil)
            let homeSubmenu = NSMenu()
            for home in homes {
                let name = home["name"] as? String ?? "?"
                let id = home["id"] as? String ?? ""
                let isSelected = home["is_selected"] as? Bool ?? false
                let item = NSMenuItem(
                    title: name, action: #selector(selectHome(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                if isSelected { item.state = .on }
                homeSubmenu.addItem(item)
            }
            homeItem.submenu = homeSubmenu
            menu.addItem(homeItem)
        } else {
            let homeItem = NSMenuItem(title: selectedHome, action: nil, keyEquivalent: "")
            homeItem.image = NSImage(
                systemSymbolName: "house.fill", accessibilityDescription: nil)
            menu.addItem(homeItem)
        }

        // Settings and Launch at Login right below the home selector
        addAppItems(to: menu)

        menu.addItem(.separator())

        // Scenes
        if !scenes.isEmpty {
            addSectionHeader("Scenes", to: menu)
            for scene in scenes {
                let name = scene["name"] as? String ?? "?"
                let id = scene["id"] as? String ?? ""
                let type = scene["type"] as? String ?? "user_defined"
                let item = NSMenuItem(
                    title: name, action: #selector(triggerScene(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                item.image = NSImage(
                    systemSymbolName: symbolForSceneType(type),
                    accessibilityDescription: nil)
                item.indentationLevel = 1
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // Rooms with accessories, separated by room
        for room in rooms {
            let roomName = room["name"] as? String ?? "?"
            let accessories = room["accessories"] as? [[String: Any]] ?? []
            guard !accessories.isEmpty else { continue }

            menu.addItem(.separator())
            addSectionHeader(roomName, to: menu)
            for accessory in accessories {
                addAccessoryItem(accessory, to: menu)
            }
        }
    }

    private func addSectionHeader(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 0)])
        menu.addItem(item)
    }

    /// Categories that are infrastructure devices — never shown in the menu.
    private static let hiddenCategories: Set<String> = [
        "bridge", "range_extender",
    ]

    private func addAccessoryItem(_ accessory: [String: Any], to menu: NSMenu) {
        let name = accessory["name"] as? String ?? "?"
        let id = accessory["id"] as? String ?? ""
        let category = accessory["category"] as? String ?? "other"
        let reachable = accessory["reachable"] as? Bool ?? false
        let state = accessory["state"] as? [String: String] ?? [:]

        // Skip infrastructure devices that aren't user-controllable
        guard !Self.hiddenCategories.contains(category) else { return }

        let behavior = accessoryBehavior(category: category, state: state)

        switch behavior {
        case .toggle(let isOn):
            let item = NSMenuItem(
                title: name,
                action: reachable ? #selector(toggleAccessory(_:)) : nil,
                keyEquivalent: "")
            item.target = self
            item.representedObject = ["id": id, "category": category]
            item.image = NSImage(
                systemSymbolName: symbolForCategory(category, isOn: isOn),
                accessibilityDescription: nil)
            if isOn { item.state = .on }
            if !reachable { item.isEnabled = false }
            item.indentationLevel = 1
            menu.addItem(item)

            // Brightness as a separate item below the toggle (NSMenu items with
            // submenus don't fire their action on click — they open the submenu)
            if reachable && category == "lightbulb" && isOn {
                let currentBrightness = state["brightness"].flatMap(Int.init)
                let brightnessTitle = currentBrightness.map { "Brightness: \($0)%" } ?? "Brightness"
                let brightnessItem = NSMenuItem(
                    title: brightnessTitle, action: nil, keyEquivalent: "")
                brightnessItem.indentationLevel = 2
                let submenu = NSMenu()
                for level in [25, 50, 75, 100] {
                    let levelItem = NSMenuItem(
                        title: "\(level)%",
                        action: #selector(setBrightness(_:)),
                        keyEquivalent: "")
                    levelItem.target = self
                    levelItem.representedObject = ["id": id, "brightness": level] as [String: Any]
                    if currentBrightness == level { levelItem.state = .on }
                    submenu.addItem(levelItem)
                }
                brightnessItem.submenu = submenu
                menu.addItem(brightnessItem)
            }

        case .statusOnly(let statusText):
            let title = statusText.isEmpty ? name : "\(name) — \(statusText)"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = NSImage(
                systemSymbolName: symbolForCategory(category, isOn: true),
                accessibilityDescription: nil)
            if !reachable { item.isEnabled = false }
            item.indentationLevel = 1
            menu.addItem(item)
        }
    }

    private func addAppItems(to menu: NSMenu) {
        // Launch at Login
        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: "")
        launchItem.target = self
        let isEnabled = iOSBridge?.isLaunchAtLoginEnabled ?? false
        launchItem.image = NSImage(
            systemSymbolName: isEnabled ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: isEnabled ? "Enabled" : "Disabled")
        menu.addItem(launchItem)

        // Settings
        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(openSettings),
            keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
    }

    private func addStandardItems(to menu: NSMenu) {
        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit HomeClaw",
            action: #selector(quitApp),
            keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Accessory Behavior

    private enum AccessoryBehavior {
        case toggle(isOn: Bool)
        case statusOnly(String)
    }

    private func accessoryBehavior(
        category: String, state: [String: String]
    ) -> AccessoryBehavior {
        switch category {
        // Toggleable — user can tap to switch on/off
        case "lightbulb", "switch", "outlet":
            return .toggle(isOn: state["power"] == "true")

        case "fan", "air_purifier", "valve":
            return .toggle(isOn: state["active"] == "1")

        case "window_covering":
            let pos = state["current_position"].flatMap(Int.init) ?? 0
            return .toggle(isOn: pos > 0)

        // Status-only — display current reading, no toggle action
        case "thermostat":
            let temp = state["current_temperature"] ?? "?"
            let mode = state["current_heating_cooling"] ?? "off"
            return .statusOnly("\(temp) (\(mode))")

        case "lock":
            return .statusOnly(state["lock_current_state"] ?? "unknown")

        case "door", "garage_door":
            return .statusOnly(state["current_door_state"] ?? "unknown")

        case "camera", "doorbell":
            return .statusOnly(state["streaming_status"] ?? "")

        case "security_system":
            return .statusOnly(state["security_system_current_state"] ?? "")

        case "programmable_switch", "speaker", "television", "network":
            return .statusOnly("")

        case "sensor":
            if let temp = state["current_temperature"] { return .statusOnly(temp) }
            if let humidity = state["current_humidity"] {
                return .statusOnly("\(humidity)% humidity")
            }
            if let motion = state["motion_detected"] {
                return .statusOnly(motion == "true" ? "motion" : "clear")
            }
            if let contact = state["contact_state"] {
                return .statusOnly(contact == "0" ? "closed" : "open")
            }
            if let battery = state["battery_level"] {
                return .statusOnly("\(battery)% battery")
            }
            return .statusOnly("")

        // Unknown category — default to status-only to avoid accidental toggling
        default:
            return .statusOnly("")
        }
    }

    // MARK: - SF Symbols

    private func symbolForCategory(_ category: String, isOn: Bool) -> String {
        switch category {
        case "lightbulb": return isOn ? "lightbulb.fill" : "lightbulb.slash"
        case "fan": return isOn ? "fan.fill" : "fan.slash"
        case "outlet": return isOn ? "powerplug.fill" : "powerplug"
        case "switch": return isOn ? "lightswitch.on.fill" : "lightswitch.off"
        case "thermostat": return "thermometer.medium"
        case "lock": return "lock.fill"
        case "garage_door": return "door.garage.closed"
        case "door": return "door.left.hand.closed"
        case "window_covering": return "blinds.vertical.closed"
        case "sensor": return "sensor"
        case "camera": return "video.fill"
        case "doorbell": return "bell.fill"
        case "security_system": return "shield.fill"
        case "air_purifier": return isOn ? "air.purifier.fill" : "air.purifier"
        case "valve": return isOn ? "spigot.fill" : "spigot"
        case "television": return "tv"
        case "speaker": return "hifispeaker.fill"
        case "network": return "network"
        case "programmable_switch": return "button.programmable"
        default: return "square.grid.2x2"
        }
    }

    private func symbolForSceneType(_ type: String) -> String {
        switch type {
        case "wake_up": return "sunrise.fill"
        case "sleep": return "moon.fill"
        case "leave": return "figure.walk"
        case "arrive": return "house.fill"
        default: return "star.fill"
        }
    }

    // MARK: - Actions

    @objc private func toggleAccessory(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let id = info["id"],
              let category = info["category"]
        else { return }

        let isCurrentlyOn = sender.state == .on

        let characteristic: String
        let newValue: String
        switch category {
        case "fan", "air_purifier", "valve":
            characteristic = "active"
            newValue = isCurrentlyOn ? "0" : "1"
        case "window_covering":
            characteristic = "target_position"
            newValue = isCurrentlyOn ? "0" : "100"
        default:
            characteristic = "power"
            newValue = isCurrentlyOn ? "false" : "true"
        }

        iOSBridge?.controlAccessory(id: id, characteristic: characteristic, value: newValue)
    }

    @objc private func setBrightness(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let id = info["id"] as? String,
              let level = info["brightness"] as? Int
        else { return }

        iOSBridge?.controlAccessory(id: id, characteristic: "brightness", value: "\(level)")
    }

    @objc private func triggerScene(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        iOSBridge?.triggerScene(id: id)
    }

    @objc private func selectHome(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        iOSBridge?.selectHome(id: id)
    }

    @objc private func toggleLaunchAtLogin() {
        guard let bridge = iOSBridge else { return }
        let newValue = !bridge.isLaunchAtLoginEnabled
        bridge.setLaunchAtLogin(newValue)
        rebuildMenu()
    }

    @objc private func openSettings() {
        iOSBridge?.openSettings()
    }

    @objc private func quitApp() {
        iOSBridge?.quitApp()
    }
}
