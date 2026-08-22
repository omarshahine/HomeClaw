import ArgumentParser
import Testing
@testable import homeclaw_cli

// Argument-parsing contract tests for every homeclaw-cli command.
//
// These assert the CLI's *surface*: which arguments are required, what the
// long-flag names resolve to, default values, and multi-value parsing. They run
// without a socket (parse stops before run()), so they cover the one layer that
// is testable in CI today. A failure here means a refactor silently changed the
// public CLI contract — e.g. renamed a flag an agent or script depends on.
//
// Commands whose validation lives in a validate() hook or a static helper are
// covered more deeply elsewhere (AddConditionTests, CreateTimeTests,
// AutomationsHelperTests). Here we focus on parse-time structure.

// MARK: - Read commands

@Suite("list / get / search / status parsing")
struct ReadCommandParsingTests {
    @Test("list takes optional --room and --category filters")
    func list() throws {
        let cmd = try List.parse(["--room", "Kitchen", "--category", "lightbulb", "--json"])
        #expect(cmd.room == "Kitchen")
        #expect(cmd.category == "lightbulb")
        #expect(cmd.json == true)
    }

    @Test("list parses with no arguments (all filters optional)")
    func listBare() throws {
        let cmd = try List.parse([])
        #expect(cmd.room == nil)
        #expect(cmd.category == nil)
        #expect(cmd.json == false)
    }

    // Regression for issue #72: the --category filter must be applied regardless
    // of output format. Previously the JSON path returned the raw, unfiltered
    // payload while only the text path filtered.
    @Test("list --category filter applies (used by both text and JSON output)")
    func listCategoryFilter() {
        let accessories: [[String: Any]] = [
            ["name": "Garage", "category": "garage_door"],
            ["name": "Lamp", "category": "lightbulb"],
            ["name": "Other Garage", "category": "Garage_Door"], // case-insensitive
        ]

        let filtered = List.filterByCategory(accessories, category: "garage_door")
        #expect(filtered.count == 2)
        #expect(filtered.allSatisfy { ($0["category"] as? String)?.lowercased() == "garage_door" })

        // No category → unchanged passthrough.
        let unfiltered = List.filterByCategory(accessories, category: nil)
        #expect(unfiltered.count == 3)

        // Non-matching category → empty.
        #expect(List.filterByCategory(accessories, category: "thermostat").isEmpty)
    }

    @Test("get requires an accessory positional and exposes --no-refresh")
    func get() throws {
        let cmd = try Get.parse(["Floor Lamp", "--no-refresh"])
        #expect(cmd.accessory == "Floor Lamp")
        #expect(cmd.noRefresh == true)
        #expect(cmd.json == false)
    }

    @Test("get without an accessory is rejected")
    func getMissingAccessory() {
        #expect(throws: (any Error).self) { _ = try Get.parse([]) }
    }

    @Test("search requires a query and takes optional --category")
    func search() throws {
        let cmd = try Search.parse(["lamp", "--category", "lightbulb"])
        #expect(cmd.query == "lamp")
        #expect(cmd.category == "lightbulb")
    }

    @Test("search without a query is rejected")
    func searchMissingQuery() {
        #expect(throws: (any Error).self) { _ = try Search.parse([]) }
    }

    @Test("status takes only --json")
    func status() throws {
        #expect(try Status.parse([]).json == false)
        #expect(try Status.parse(["--json"]).json == true)
    }
}

// MARK: - set

@Suite("set parsing")
struct SetCommandParsingTests {
    @Test("three positionals required: accessory, characteristic, value")
    func validSet() throws {
        let cmd = try Set.parse(["Floor Lamp", "power", "on"])
        #expect(cmd.accessory == "Floor Lamp")
        #expect(cmd.characteristic == "power")
        #expect(cmd.value == "on")
        #expect(cmd.dryRun == false)
    }

    @Test("--service-type and --dry-run are parsed")
    func optionalFlags() throws {
        let cmd = try Set.parse(["Lamp", "brightness", "50", "--service-type", "uuid-123", "--dry-run", "--json"])
        #expect(cmd.serviceType == "uuid-123")
        #expect(cmd.dryRun == true)
        #expect(cmd.json == true)
    }

    @Test("missing value positional rejected")
    func missingValue() {
        #expect(throws: (any Error).self) { _ = try Set.parse(["Lamp", "power"]) }
    }

    // Regression for issue #85: every channel of a multi-gang switch shares one
    // service type, so --service-type alone can't pick a channel. --service-name
    // and --service-index are the selectors that can.
    @Test("--service-name and --service-index are parsed")
    func perServiceSelectors() throws {
        let cmd = try Set.parse(["Wall Switch", "power", "true", "--service-name", "Pendentes", "--service-index", "3"])
        #expect(cmd.serviceName == "Pendentes")
        #expect(cmd.serviceIndex == 3)
        #expect(cmd.serviceType == nil)
    }

    @Test("service selectors default to nil")
    func selectorsDefaultNil() throws {
        let cmd = try Set.parse(["Lamp", "power", "on"])
        #expect(cmd.serviceName == nil)
        #expect(cmd.serviceIndex == nil)
    }

    // The ambiguity error tells users to retry with service_id, so the flag it names
    // has to exist and resolve to exactly that spelling.
    @Test("--service-id is parsed")
    func serviceIDSelector() throws {
        let cmd = try Set.parse(["Wall Switch", "power", "true", "--service-id", "B3E0-UUID"])
        #expect(cmd.serviceID == "B3E0-UUID")
        #expect(cmd.serviceName == nil)
    }

    @Test("--service-index rejects non-numeric input")
    func serviceIndexMustBeNumeric() {
        #expect(throws: (any Error).self) {
            _ = try Set.parse(["Lamp", "power", "on", "--service-index", "first"])
        }
    }

    // Verification is on by default; --no-verify is the opt-out for accessories whose
    // readback is unreliable.
    @Test("--no-verify defaults off and parses")
    func noVerifyFlag() throws {
        #expect(try Set.parse(["Lamp", "power", "on"]).noVerify == false)
        #expect(try Set.parse(["Lamp", "power", "on", "--no-verify"]).noVerify == true)
    }
}

// MARK: - scenes

@Suite("scene command parsing")
struct SceneCommandParsingTests {
    @Test("scenes list takes only --json")
    func scenes() throws {
        #expect(try Scenes.parse(["--json"]).json == true)
    }

    @Test("trigger requires a scene positional")
    func trigger() throws {
        #expect(try Trigger.parse(["Good Night"]).scene == "Good Night")
        #expect(throws: (any Error).self) { _ = try Trigger.parse([]) }
    }

    @Test("get-scene requires a scene and takes --home")
    func getScene() throws {
        let cmd = try GetScene.parse(["Movie Time", "--home", "My Home"])
        #expect(cmd.scene == "Movie Time")
        #expect(cmd.home == "My Home")
    }

    @Test("import-scene requires a file path and defaults dry-run off")
    func importScene() throws {
        let cmd = try ImportScene.parse(["/tmp/scene.json"])
        #expect(cmd.file == "/tmp/scene.json")
        #expect(cmd.dryRun == false)
    }

    @Test("update-scene requires a file path")
    func updateScene() throws {
        #expect(try UpdateScene.parse(["/tmp/s.json", "--dry-run"]).dryRun == true)
        #expect(throws: (any Error).self) { _ = try UpdateScene.parse([]) }
    }

    @Test("delete-scene requires a name")
    func deleteScene() throws {
        #expect(try DeleteScene.parse(["Old Scene"]).name == "Old Scene")
        #expect(throws: (any Error).self) { _ = try DeleteScene.parse([]) }
    }
}

// MARK: - events / webhook-log (numeric + since options)

@Suite("events / webhook-log parsing")
struct EventsParsingTests {
    @Test("events defaults limit to 50 and parses --type / --since")
    func events() throws {
        let cmd = try Events.parse(["--limit", "10", "--type", "scene_triggered", "--since", "1h"])
        #expect(cmd.limit == 10)
        #expect(cmd.type == "scene_triggered")
        #expect(cmd.since == "1h")
    }

    @Test("events limit default is 50 when omitted")
    func eventsDefaultLimit() throws {
        #expect(try Events.parse([]).limit == 50)
    }

    @Test("non-integer --limit is rejected by the parser")
    func eventsBadLimit() {
        #expect(throws: (any Error).self) { _ = try Events.parse(["--limit", "lots"]) }
    }

    @Test("webhook-log list parses limit/outcome/since")
    func webhookLogList() throws {
        let cmd = try WebhookLog.List.parse(["--limit", "5", "--outcome", "failed", "--since", "2d"])
        #expect(cmd.limit == 5)
        #expect(cmd.outcome == "failed")
        #expect(cmd.since == "2d")
    }

    @Test("webhook-log stats and purge take minimal arguments")
    func webhookLogStatsPurge() throws {
        #expect(try WebhookLog.Stats.parse(["--json"]).json == true)
        _ = try WebhookLog.Purge.parse([]) // no throw
    }
}

// MARK: - device-map (enum-typed option)

@Suite("device-map parsing")
struct DeviceMapParsingTests {
    @Test("--format maps onto the OutputFormat enum")
    func format() throws {
        #expect(try DeviceMapCmd.parse(["--format", "json"]).format == .json)
        #expect(try DeviceMapCmd.parse(["--format", "md"]).format == .md)
        #expect(try DeviceMapCmd.parse(["--format", "agent"]).format == .agent)
    }

    @Test("an unknown --format value is rejected")
    func badFormat() {
        #expect(throws: (any Error).self) { _ = try DeviceMapCmd.parse(["--format", "yaml"]) }
    }

    @Test("--output (-o) sets the destination file; defaults to nil")
    func output() throws {
        #expect(try DeviceMapCmd.parse(["-o", "/tmp/map.txt"]).output == "/tmp/map.txt")
        #expect(try DeviceMapCmd.parse([]).output == nil)
    }
}

// MARK: - structure mutation: rooms / zones / rename / remove

@Suite("structure command parsing")
struct StructureCommandParsingTests {
    @Test("create-room / create-zone take a name and default dry-run off")
    func create() throws {
        #expect(try CreateRoom.parse(["Garage"]).name == "Garage")
        #expect(try CreateZone.parse(["Upstairs"]).name == "Upstairs")
        #expect(try CreateRoom.parse(["Garage"]).dryRun == false)
    }

    @Test("rename takes accessory + new name")
    func rename() throws {
        let cmd = try Rename.parse(["Old", "New", "--dry-run"])
        #expect(cmd.accessory == "Old")
        #expect(cmd.newName == "New")
        #expect(cmd.dryRun == true)
    }

    @Test("rename-room takes room + new name")
    func renameRoom() throws {
        let cmd = try RenameRoom.parse(["Den", "Office"])
        #expect(cmd.room == "Den")
        #expect(cmd.newName == "Office")
    }

    @Test("remove-room / remove-zone / remove-accessory take one positional")
    func removeSingles() throws {
        #expect(try RemoveRoom.parse(["Den"]).room == "Den")
        #expect(try RemoveZone.parse(["Upstairs"]).zone == "Upstairs")
        #expect(try RemoveAccessory.parse(["Lamp"]).accessory == "Lamp")
    }

    @Test("add-room-to-zone / remove-room-from-zone take room + zone")
    func zoneMembership() throws {
        let add = try AddRoomToZone.parse(["Kitchen", "Downstairs"])
        #expect(add.room == "Kitchen")
        #expect(add.zone == "Downstairs")
        let remove = try RemoveRoomFromZone.parse(["Kitchen", "Downstairs"])
        #expect(remove.room == "Kitchen")
        #expect(remove.zone == "Downstairs")
    }

    @Test("assign-rooms takes a JSON file path")
    func assignRooms() throws {
        #expect(try AssignRooms.parse(["/tmp/assign.json"]).file == "/tmp/assign.json")
        #expect(throws: (any Error).self) { _ = try AssignRooms.parse([]) }
    }

    @Test("rename-room requires both positionals")
    func renameRoomMissingArg() {
        #expect(throws: (any Error).self) { _ = try RenameRoom.parse(["Den"]) }
    }

    @Test("--home is honoured across structure commands")
    func homeOption() throws {
        #expect(try CreateRoom.parse(["Garage", "--home", "Cabin"]).home == "Cabin")
        #expect(try RemoveZone.parse(["Z", "--home", "Cabin"]).home == "Cabin")
    }
}

// MARK: - config (all-optional surface)

@Suite("config parsing")
struct ConfigParsingTests {
    @Test("config parses with no arguments (show mode)")
    func bare() throws {
        let cmd = try Config.parse([])
        #expect(cmd.defaultHome == nil)
        #expect(cmd.clear == false)
        #expect(cmd.webhookTest == false)
        #expect(cmd.listDevices == false)
    }

    @Test("home/filter/allowlist options parse")
    func settings() throws {
        let cmd = try Config.parse([
            "--default-home", "My Home",
            "--filter-mode", "allowlist",
            "--allow-accessories", "id1,id2",
        ])
        #expect(cmd.defaultHome == "My Home")
        #expect(cmd.filterMode == "allowlist")
        #expect(cmd.allowAccessories == "id1,id2")
    }

    @Test("webhook options and flags parse")
    func webhook() throws {
        let cmd = try Config.parse([
            "--webhook-url", "http://127.0.0.1:18789",
            "--webhook-token", "secret",
            "--webhook-enabled", "true",
        ])
        #expect(cmd.webhookURL == "http://127.0.0.1:18789")
        #expect(cmd.webhookToken == "secret")
        #expect(cmd.webhookEnabled == "true")
    }

    @Test("standalone flags parse: --clear, --webhook-test, --webhook-reset, --list-devices")
    func flags() throws {
        #expect(try Config.parse(["--clear"]).clear == true)
        #expect(try Config.parse(["--webhook-test"]).webhookTest == true)
        #expect(try Config.parse(["--webhook-reset"]).webhookReset == true)
        #expect(try Config.parse(["--list-devices"]).listDevices == true)
    }
}

// MARK: - triggers (webhook routing)

@Suite("triggers parsing")
struct TriggersParsingTests {
    @Test("triggers list takes only --json")
    func list() throws {
        #expect(try ListTriggers.parse(["--json"]).json == true)
    }

    @Test("add requires --label and parses routing options")
    func add() throws {
        let cmd = try AddTrigger.parse([
            "--label", "Front door opened",
            "--accessory-id", "uuid-1",
            "--characteristic", "contact_state",
            "--value", "open",
            "--action", "agent",
            "--agent-prompt", "Someone is at the door",
            "--agent-deliver",
        ])
        #expect(cmd.label == "Front door opened")
        #expect(cmd.accessoryId == "uuid-1")
        #expect(cmd.characteristic == "contact_state")
        #expect(cmd.value == "open")
        #expect(cmd.action == "agent")
        #expect(cmd.agentPrompt == "Someone is at the door")
        #expect(cmd.agentDeliver == true)
    }

    @Test("add without --label is rejected")
    func addMissingLabel() {
        #expect(throws: (any Error).self) { _ = try AddTrigger.parse(["--characteristic", "x"]) }
    }

    @Test("remove requires a trigger id positional")
    func remove() throws {
        #expect(try RemoveTrigger.parse(["trigger-uuid"]).id == "trigger-uuid")
        #expect(throws: (any Error).self) { _ = try RemoveTrigger.parse([]) }
    }

    @Test("update takes an id plus optional fields")
    func update() throws {
        let cmd = try UpdateTrigger.parse(["trigger-uuid", "--label", "Renamed", "--enabled", "false"])
        #expect(cmd.id == "trigger-uuid")
        #expect(cmd.label == "Renamed")
        #expect(cmd.enabled == "false")
    }
}

// MARK: - automations (subcommand tree)

@Suite("automations parsing")
struct AutomationsParsingTests {
    @Test("list takes optional --home")
    func list() throws {
        #expect(try ListAutomations.parse(["--home", "Cabin"]).home == "Cabin")
        #expect(try ListAutomations.parse([]).home == nil)
    }

    @Test("get / delete / enable / disable require an id")
    func idCommands() throws {
        #expect(try GetAutomation.parse(["Porch"]).id == "Porch")
        #expect(try DeleteAutomation.parse(["Porch"]).id == "Porch")
        #expect(try EnableAutomation.parse(["Porch"]).id == "Porch")
        #expect(try DisableAutomation.parse(["Porch"]).id == "Porch")
        #expect(throws: (any Error).self) { _ = try GetAutomation.parse([]) }
    }

    @Test("create requires --name and --accessory; --press defaults to single")
    func createDefaults() throws {
        let cmd = try CreateAutomation.parse([
            "--name", "Porch", "--accessory", "Button", "--scene", "Porch On",
        ])
        #expect(cmd.name == "Porch")
        #expect(cmd.accessory == "Button")
        #expect(cmd.scene == "Porch On")
        #expect(cmd.press == "single")
        #expect(cmd.action.isEmpty)
        #expect(cmd.duration == nil)
    }

    @Test("create without --name or --accessory is rejected")
    func createMissingRequired() {
        #expect(throws: (any Error).self) { _ = try CreateAutomation.parse(["--name", "X"]) }
        #expect(throws: (any Error).self) { _ = try CreateAutomation.parse(["--accessory", "Y"]) }
    }

    @Test("create collects repeatable --action / --condition into arrays")
    func createMultiValue() throws {
        let cmd = try CreateAutomation.parse([
            "--name", "Motion Lights",
            "--accessory", "Motion Sensor",
            "--characteristic", "motion_detected",
            "--trigger-value", "true",
            "--action", "Lamp:power:on", "Strip:power:on",
            "--condition", "Front Door:contact_state:0",
            "--duration", "300",
        ])
        #expect(cmd.action == ["Lamp:power:on", "Strip:power:on"])
        #expect(cmd.condition == ["Front Door:contact_state:0"])
        #expect(cmd.characteristic == "motion_detected")
        #expect(cmd.triggerValue == "true")
        #expect(cmd.duration == 300)
    }

    @Test("create-time requires --name and --time")
    func createTime() throws {
        let cmd = try CreateTimeAutomation.parse([
            "--name", "Coffee", "--time", "06:30",
            "--action", "Coffee Maker:power:1",
            "--days", "mon,tue,wed,thu,fri",
        ])
        #expect(cmd.name == "Coffee")
        #expect(cmd.time == "06:30")
        #expect(cmd.days == "mon,tue,wed,thu,fri")
        #expect(throws: (any Error).self) { _ = try CreateTimeAutomation.parse(["--name", "X"]) }
    }

    @Test("rewire collects repeatable --add-scene / --remove-scene")
    func rewire() throws {
        let cmd = try RewireAutomation.parse([
            "Porch",
            "--add-scene", "Scene A", "--add-scene", "Scene B",
            "--remove-scene", "Scene C",
        ])
        #expect(cmd.id == "Porch")
        #expect(cmd.addScene == ["Scene A", "Scene B"])
        #expect(cmd.removeScene == ["Scene C"])
    }
}
