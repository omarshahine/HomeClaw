---
description: |
  Control HomeKit smart home accessories via HomeClaw MCP tools.
  Also includes reference data for accessory categories, characteristics, and value formats.
  This skill should be used when the user wants to:
  - Turn lights on or off, set brightness, or change color temperature
  - Lock or unlock doors
  - Set thermostat temperature or HVAC mode
  - Run a HomeKit scene like "Good Morning" or "Movie Time"
  - Check which devices are on, off, or unreachable
  - List accessories in a room or search by name
  - Check HomeClaw status or configure default home
  - Look up characteristic names, value types, ranges, or enum mappings
  Example triggers: "turn on the kitchen lights", "lock all doors",
  "set the thermostat to 72", "run the goodnight scene", "what lights are on",
  "list devices in the living room", "is HomeClaw running",
  "what characteristics does a thermostat have", "what are the lock state values"
---

# HomeKit Smart Home Control

HomeClaw exposes Apple HomeKit accessories via MCP tools. Use the `homekit_*` tools as the interface for all HomeKit operations.

## MCP Tools

The plugin registers 8 MCP tools.

| Tool | Description |
|------|-------------|
| `homekit_status` | Check bridge connectivity, home count, accessory count |
| `homekit_accessories` | List, get details, search, or control accessories |
| `homekit_rooms` | List rooms and their accessories |
| `homekit_scenes` | List, get details of, trigger, import, or delete scenes |
| `homekit_device_map` | Get LLM-optimized device map with semantic types, aliases, and zone hierarchy |
| `homekit_events` | Query recent HomeKit events (characteristic changes, scene triggers, control actions) |
| `homekit_automations` | Manage automations: list, create (inline actions or scene), delete, enable/disable |
| `homekit_webhook` | Manage webhook configuration: setup, test, reset circuit breaker, status |
| `homekit_config` | View or update bridge configuration |

### homekit_device_map

Returns a complete LLM-optimized device map organized by home/zone/room hierarchy. Each device includes:

| Field | Description |
|-------|-------------|
| `semantic_type` | Functional type: `lighting`, `climate`, `security`, `door_lock`, `window_covering`, `sensor`, `power`, `media`, `network`, `other` |
| `display_name` | Room-prefixed name for disambiguation (only when duplicates exist) |
| `aliases` | Auto-generated search terms like "kitchen light", "overhead in kitchen" |
| `controllable` | List of writable characteristics (e.g., `["power", "brightness"]`) |
| `state_summary` | One-line state: "on 75%", "72°F heating", "locked", "off", "unreachable" |
| `manufacturer` | Device manufacturer |
| `description` | Natural-language summary: "Lutron lighting (power, brightness), on 75%" |

**Use this tool first** when you need to understand the device landscape before controlling devices. It resolves name collisions and identifies switches that actually control lights.

### Semantic Type Reference

| Semantic Type | Maps From | Key Distinction |
|--------------|-----------|-----------------|
| `lighting` | lightbulbs | Devices with brightness/color control |
| `climate` | thermostats, fans, air purifiers | |
| `security` | doors, garage doors, cameras, doorbells, security systems | |
| `door_lock` | locks | |
| `window_covering` | windows, blinds, shades | |
| `sensor` | motion, contact, temperature, humidity sensors | |
| `power` | outlets, switches, programmable switches | In-wall switches get light aliases for search |
| `media` | speakers, televisions | |

### homekit_accessories

The main workhorse tool. Supports 4 actions via the `action` parameter:

| Action | Required Params | Description |
|--------|----------------|-------------|
| `list` | — | List all accessories. Optional: `room`. Returns enriched results with `semantic_type`, `display_name`, `manufacturer`, `zone`. |
| `get` | `accessory_id` | Get full detail with all characteristics |
| `search` | `query` | Search by name, room, category, semantic type, manufacturer, or aliases (e.g., "kitchen light" matches switches with lightbulb services). Optional: `category` |
| `control` | `accessory_id`, `characteristic`, `value` | Set a characteristic value |

### homekit_scenes

| Action | Required Params | Description |
|--------|----------------|-------------|
| `list` | — | List all scenes with name, type, and action count |
| `get` | `scene_id` | Get full scene detail including all actions (accessory, room, characteristic, target value) |
| `trigger` | `scene_id` | Execute a scene by name or UUID |

### homekit_events

| Param | Required | Description |
|-------|----------|-------------|
| `since` | No | Duration shorthand (`1h`, `30m`, `2d`) or ISO 8601 timestamp |
| `type` | No | Filter: `characteristic_change`, `scene_triggered`, `accessory_controlled`, `homes_updated` |
| `limit` | No | Max events to return (default: 50) |

### homekit_automations

| Action | Required Params | Description |
|--------|----------------|-------------|
| `list` | — | List all automations with event summaries and linked scenes |
| `get` | `id` | Detail view with events, action sets, and button info |
| `create` | `name`, `accessory_id`, plus `actions` or `scene_id` | Create a button-press automation (see below) |
| `delete` | `id` | Delete an automation |
| `enable` | `id` | Enable a disabled automation |
| `disable` | `id` | Disable an automation without deleting |

**Create parameters:**

| Param | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Human-readable automation name |
| `accessory_id` | Yes | Button accessory UUID or name |
| `actions` | One of | Inline actions array (default, no visible scene). Each entry: `{accessory, property, value}` |
| `scene_id` | One of | Existing scene UUID or name to trigger |
| `press_type` | No | 0=single (default), 1=double, 2=long press |
| `service_index` | No | Button index for multi-button accessories (1 or 2) |
| `dry_run` | No | Preview without creating |

**Inline actions vs scenes:** Use `actions` for simple button-to-device mappings (creates a scene named after the automation). Use `scene_id` to trigger an existing shared scene. Note: Apple's Home app uses a private API for hidden automation-only action sets; inline actions created via HomeClaw will appear as visible scenes.

### homekit_config

| Action | Required Params | Description |
|--------|----------------|-------------|
| `get` | — | Show current configuration |
| `set` | at least one setting | Set `default_home_id`, `accessory_filter_mode`, `allowed_accessory_ids`, or `temperature_unit` |

## Common Workflows

### Turn on a light

1. Search for the light: `homekit_accessories` with `action: "search"`, `query: "kitchen"`
2. Identify the accessory UUID from the results
3. Turn it on: `homekit_accessories` with `action: "control"`, `accessory_id: "<uuid>"`, `characteristic: "power"`, `value: "true"`

### Set brightness

1. Find the light UUID (via search or list)
2. Set brightness: `homekit_accessories` with `action: "control"`, `accessory_id: "<uuid>"`, `characteristic: "brightness"`, `value: "50"`

### Lock all doors

1. Find all locks: `homekit_accessories` with `action: "search"`, `category: "lock"`
2. For each lock: `homekit_accessories` with `action: "control"`, `accessory_id: "<uuid>"`, `characteristic: "lock_target_state"`, `value: "locked"`

### Check temperature

1. Find thermostats: `homekit_accessories` with `action: "search"`, `category: "thermostat"`
2. Get details: `homekit_accessories` with `action: "get"`, `accessory_id: "<uuid>"`
3. Read the `current_temperature` characteristic from the response

### Set thermostat

1. Find the thermostat UUID (via search)
2. Set temperature: `homekit_accessories` with `action: "control"`, `accessory_id: "<uuid>"`, `characteristic: "target_temperature"`, `value: "72"`
3. Set mode: `homekit_accessories` with `action: "control"`, `accessory_id: "<uuid>"`, `characteristic: "target_heating_cooling"`, `value: "auto"`

### Run a scene

1. List scenes: `homekit_scenes` with `action: "list"`
2. Trigger: `homekit_scenes` with `action: "trigger"`, `scene_id: "Movie Time"`

### Inspect what a scene does

1. Get scene detail: `homekit_scenes` with `action: "get"`, `scene_id: "Good night"`
2. Response includes all actions: accessory name, room, characteristic, and target value

### List accessories by room

1. Filter by room: `homekit_accessories` with `action: "list"`, `room: "Living Room"`

### Switch active home

1. Configure: `homekit_config` with `action: "set"`, `default_home_id: "My Home"`

### Program a button (inline actions)

Creates a scene named after the automation and links it to the button press. **Always use UUIDs for target accessories** to avoid name collisions (many accessories share names like "Overhead" or "Blinds" across rooms).

1. Find the button: `homekit_accessories` with `action: "search"`, `query: "Office Button"`
2. Find target devices and note their UUIDs: `homekit_accessories` with `action: "list"`, `room: "Sarah's Bedroom"`
3. Check button services: `homekit_accessories` with `action: "get"`, `accessory_id: "<button-uuid>"` to see how many buttons and press types (`input_event` max: 0=single only, 2=single+double+long)
4. Create automation: `homekit_automations` with `action: "create"`, `name: "Room Open"`, `accessory_id: "<button-uuid>"`, `actions: [{accessory: "<light-uuid>", property: "power", value: "true"}, {accessory: "<blind-uuid>", property: "target_position", value: "100"}]`, `press_type: 0`, `service_index: 1`

### Program a button (with a named scene)

Use when the automation should trigger an existing scene:

1. Find the button and identify the scene
2. Create automation: `homekit_automations` with `action: "create"`, `name: "Button → Movie Time"`, `accessory_id: "<button-uuid>"`, `scene_id: "Movie Time"`, `press_type: 0`

### Edit a scene's actions in place (CLI)

Repoints an existing scene at different accessories/values **without changing its UUID**, so automations that trigger it stay wired. Only `update-scene` / `import-scene` (CLI) can do this — there is no MCP tool for it. Common use: point a slow "set each shade" scene at a single vendor "scene switch" so one press moves everything at once.

1. Inspect current actions: `homeclaw-cli get-scene "Main Blinds - Open" --json`
2. Write the new definition. Actions are `{"accessory", "property", "value"}`; `characteristic` is accepted as an alias for `property`, so `get-scene` output round-trips. Reference accessories by **UUID** when names collide.
   ```json
   { "name": "Main Blinds - Open",
     "actions": [ { "accessory": "Open Main Blinds", "property": "power", "value": "1" } ] }
   ```
3. Dry-run, then apply. Pipe via stdin (`-`) to avoid the sandbox file limit below:
   ```
   cat scene.json | homeclaw-cli update-scene - --dry-run    # check resolved_actions
   cat scene.json | homeclaw-cli update-scene -
   ```
   `--dry-run` reports `resolved_actions`; if it's below your action count, an accessory/property didn't resolve — read the `warnings`.

> **Sandbox file access.** `homeclaw-cli` is sandboxed to the app group, so it can only open files under `~/Library/Group Containers/group.com.shahine.homeclaw/` (or system paths). Files in `/tmp`, `~/Desktop`, or agent temp dirs fail with *"couldn't be opened because you don't have permission to view it"* — this is **not** fixed by granting Full Disk Access. Pipe JSON via stdin (`-`), or place the file in the group container.

### Detach a hidden scene from a button (CLI)

Buttons sometimes carry hidden, trigger-owned scenes (e.g. an auto-generated close-all fired alongside an open) that `get-scene` can see but `update-scene`/`delete-scene` cannot edit (they only search visible scenes). Detach them from the automation instead:

1. Find the automation: `homeclaw-cli automations list --json`
2. Detach the scene (`--add-scene`/`--remove-scene` repeatable, `--dry-run` supported, trigger UUID preserved):
   ```
   homeclaw-cli automations rewire "<automation id>" --remove-scene "<scene name or uuid>" --dry-run
   homeclaw-cli automations rewire "<automation id>" --remove-scene "<scene name or uuid>"
   ```

### Button modes and service_index

Programmable switches (Aqara, Hue, etc.) may operate in different modes:

- **Fast mode**: Multiple buttons (e.g., Button 1 and Button 2), each single-press only. Fires instantly with no delay. Identified by `input_event` metadata `max: 0` on each service.
- **Multi-event mode**: One button with single, double, and long press. Adds ~300ms delay to detect press type. Identified by `input_event` metadata `max: 2`.

Use `--service-index` (CLI) or `service_index` (MCP) to target a specific button in fast mode. The mode itself is configured in the manufacturer's app (e.g., Aqara Home), not via HomeKit.

### Name each gang of a multi-gang accessory, and set Display As

A dual relay (e.g. Aqara Dual Relay T2) is one accessory with two switch services; every gang shares the accessory UUID and serial. Separating its tiles in the Home app only changes layout. Plain `rename` names the accessory and its primary tile only — name the other gang by service:

```bash
homeclaw-cli get "Downlight 1" --json          # services[] lists each gang's id, name, index, display_as
homeclaw-cli rename "Downlight 1" "Downlight 2" --service-name "Switch 2"   # or --service-index 2 / --service-id <uuid>
homeclaw-cli rename <service-uuid> "Downlight 2"                            # a service UUID also works as the target
homeclaw-cli set-display-as "Downlight 1" light --service-name "Downlight 2" --dry-run
```

MCP: `homekit_manage` with `action: "rename"` or `action: "set_display_as"` plus `service_name` / `service_index` / `service_id`. This writes the home's service name, so it works even when the gang's HAP `name` characteristic is read-only. Display As (`light`, `fan`, or the service's own `switch` / `outlet`; `default` restores it) applies only to switch and outlet services — a gang bridged over Matter as a light has no Display As, in the Home app or here.

## Error Handling

| Error | Cause | Resolution |
|-------|-------|------------|
| "HomeClaw is not running" | App not launched or socket missing | Launch HomeClaw.app |
| "Connection failed" | Socket exists but app not responding | Restart the app |
| 0 homes / `ready: false` | Missing entitlement or iCloud not signed in | Check codesign entitlements and iCloud |
| "Accessory not found" | Wrong UUID or name | Use `search` to find the correct identifier |
| "Characteristic not writable" | Trying to set a read-only characteristic | Check the writable column in the characteristics tables below |
| Values show `"nil"` | Accessory is unreachable or bridge hasn't synced | Check `reachable` field; unreachable devices return `nil` for all state values |
| "couldn't be opened because you don't have permission to view it" | `update-scene`/`import-scene` given a file outside the sandbox (e.g. `/tmp`) | CLI is app-sandboxed — pipe JSON via stdin (`homeclaw-cli update-scene -`) or put the file under `~/Library/Group Containers/group.com.shahine.homeclaw/`. FDA does not help. |
| "Scene not found" on `update-scene` for a scene `get-scene` can see | It's a hidden, trigger-owned scene | Use `automations rewire <automation> --remove-scene <scene>` to detach it; it can't be edited in place |
| Dry-run shows `resolved_actions: 0` with "missing fields" | Action used `characteristic` on an old build, or lacks `accessory`/`property`/`value` | Use `property` (or update to a build where `characteristic` is an accepted alias); ensure all three keys are present |

## Configuration

Config file: `~/.config/homeclaw/config.json`

| Setting | Values | Default |
|---------|--------|---------|
| `default_home_id` | Home name or UUID | Primary home |
| `accessory_filter_mode` | `all`, `allowlist` | `all` |
| `allowed_accessory_ids` | Array of UUIDs | `[]` |
| `temperature_unit` | `fahrenheit`, `celsius`, `auto` | `auto` (uses system locale) |

Use `homekit_config` to view and modify settings. When `temperature_unit` changes, the characteristic cache is automatically invalidated and refreshed.

---

## Accessory Categories

Categories are mapped from Apple's `HMAccessoryCategoryType` constants. Homebridge devices that don't map to a known category will show the raw UUID string.

| Category | Description |
|----------|-------------|
| `lightbulb` | Lights, bulbs, LED strips |
| `switch` | Generic on/off switches |
| `outlet` | Smart plugs and outlets |
| `fan` | Ceiling fans, standing fans |
| `thermostat` | HVAC thermostats |
| `lock` | Door locks |
| `door` | Door sensors/controllers |
| `garage_door` | Garage door openers |
| `window` | Window actuators |
| `window_covering` | Blinds, shades, curtains |
| `sensor` | Temperature, humidity, motion, contact sensors |
| `security_system` | Home security systems |
| `programmable_switch` | Buttons, remote controls |
| `air_purifier` | Air purifiers and filters |
| `camera` | IP cameras |
| `doorbell` | Video doorbells |
| `speaker` | Speakers, cameras with audio (UniFi Protect cameras show as speaker) |
| `valve` | Water valves, sprinkler controllers (Water Shutoff, Eve Aqua) |
| `bridge` | HomeKit bridges (Homebridge, Hue Bridge, etc.) |
| `range_extender` | Network range extenders |

## Characteristics by Category

### Lightbulb
| Characteristic | Type | Range | Writable |
|---------------|------|-------|----------|
| `power` | boolean | true/false | Yes |
| `brightness` | integer | 0-100 | Yes |
| `hue` | float | 0-360 | Yes |
| `saturation` | float | 0-100 | Yes |
| `color_temperature` | integer | 140-500 (mireds) | Yes |

### Thermostat
| Characteristic | Type | Range | Writable |
|---------------|------|-------|----------|
| `current_temperature` | string | Formatted with unit, e.g. `"71°F"` | No |
| `target_temperature` | string | Formatted with unit, e.g. `"70°F"`. Set with plain number in user's unit. | Yes |
| `current_heating_cooling` | enum | 0-3 | No |
| `target_heating_cooling` | enum | 0-3 | Yes |
| `temperature_units` | enum | 0=Celsius, 1=Fahrenheit | No |
| `current_humidity` | float | 0-100 | No |
| `target_humidity` | float | 0-100 | Yes |

> **Note**: Temperature values are returned as formatted strings with the user's preferred unit (e.g., `"71°F"` or `"22°C"`). This applies to all `current_temperature` readings across all accessory types (thermostats, sensors, leak detectors, etc.).

### Lock
| Characteristic | Type | Range | Writable |
|---------------|------|-------|----------|
| `lock_current_state` | enum | 0-3 | No |
| `lock_target_state` | enum | 0-1 | Yes |

### Door / Garage Door
| Characteristic | Type | Range | Writable |
|---------------|------|-------|----------|
| `current_door_state` | enum | 0-4 | No |
| `target_door_state` | enum | 0-1 | Yes |
| `obstruction_detected` | boolean | true/false | No |

### Fan
| Characteristic | Type | Range | Writable |
|---------------|------|-------|----------|
| `active` | boolean | true/false | Yes |
| `rotation_speed` | float | 0-100 | Yes |
| `rotation_direction` | enum | 0=clockwise, 1=counter | Yes |
| `swing_mode` | enum | 0=disabled, 1=enabled | Yes |
| `current_fan_state` | enum | 0-2 | No |
| `target_fan_state` | enum | 0=manual, 1=auto | Yes |

### Window Covering
| Characteristic | Type | Range | Writable |
|---------------|------|-------|----------|
| `current_position` | integer | 0-100 | No |
| `target_position` | integer | 0-100 | Yes |
| `position_state` | enum | 0=decreasing, 1=increasing, 2=stopped | No |

### Sensor (common)
| Characteristic | Type | Range | Writable |
|---------------|------|-------|----------|
| `motion_detected` | boolean | true/false | No |
| `contact_state` | enum | 0=detected, 1=not detected | No |
| `current_temperature` | float | varies | No |
| `current_humidity` | float | 0-100 | No |
| `current_light_level` | float | 0.0001-100000 (lux) | No |
| `battery_level` | integer | 0-100 | No |
| `low_battery` | boolean | true/false | No |
| `charging_state` | enum | 0-2 | No |

## Enum Value Mappings

### Heating/Cooling State
| Value | Name | Writable as |
|-------|------|-------------|
| 0 | Off | `off` or `0` |
| 1 | Heat | `heat` or `1` |
| 2 | Cool | `cool` or `2` |
| 3 | Auto | `auto` or `3` |

### Lock State
| Value | Name | Writable as |
|-------|------|-------------|
| 0 | Unsecured | `unlocked`, `unsecured`, or `0` |
| 1 | Secured | `locked`, `secured`, or `1` |
| 2 | Jammed | (read-only) |
| 3 | Unknown | (read-only) |

### Door State
| Value | Name | Writable as |
|-------|------|-------------|
| 0 | Open | `open` or `0` |
| 1 | Closed | `closed` or `1` |
| 2 | Opening | (read-only) |
| 3 | Closing | (read-only) |
| 4 | Stopped | (read-only) |

## JSON Response Structure

### `list` / `search` Response

Each accessory includes name, id, category, room, reachability, and a summary of current state values.

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Accessory display name |
| `id` | string | UUID identifier |
| `category` | string | Category type (see above) |
| `room` | string | Room assignment |
| `reachable` | boolean | Whether accessory is online |
| `state` | object | Key-value map of current characteristic values |

### `get` Response

Full detail includes all services and their characteristics, each with name, current value, and writable flag.

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Accessory display name |
| `id` | string | UUID identifier |
| `category` | string | Category type |
| `room` | string | Room assignment |
| `reachable` | boolean | Whether accessory is online |
| `services` | array | Services with nested `characteristics` array |
| `services[].characteristics[].name` | string | Characteristic name |
| `services[].characteristics[].value` | string | Current value |
| `services[].characteristics[].writable` | boolean | Whether value can be set |

### `status` Response

| Field | Type | Description |
|-------|------|-------------|
| `ready` | boolean | Whether HomeKit is connected |
| `homes` | integer | Number of homes |
| `accessories` | integer | Number of accessories |
| `cache.cached_accessories` | integer | Number of accessories with cached values |
| `cache.is_stale` | boolean | Whether cache needs refresh |
| `cache.last_warmed` | string? | ISO timestamp of last cache warm, or null |
