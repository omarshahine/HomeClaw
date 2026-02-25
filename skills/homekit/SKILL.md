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

The plugin registers 6 MCP tools.

| Tool | Description |
|------|-------------|
| `homekit_status` | Check bridge connectivity, home count, accessory count |
| `homekit_accessories` | List, get details, search, or control accessories |
| `homekit_rooms` | List rooms and their accessories |
| `homekit_scenes` | List or trigger HomeKit scenes |
| `homekit_device_map` | Get LLM-optimized device map with semantic types, aliases, and zone hierarchy |
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
| `list` | — | List all scenes |
| `trigger` | `scene_id` | Execute a scene by name or UUID |

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

### List accessories by room

1. Filter by room: `homekit_accessories` with `action: "list"`, `room: "Living Room"`

### Switch active home

1. Configure: `homekit_config` with `action: "set"`, `default_home_id: "My Home"`

## Error Handling

| Error | Cause | Resolution |
|-------|-------|------------|
| "HomeClaw is not running" | App not launched or socket missing | Launch HomeClaw.app |
| "Connection failed" | Socket exists but app not responding | Restart the app |
| 0 homes / `ready: false` | Missing entitlement or iCloud not signed in | Check codesign entitlements and iCloud |
| "Accessory not found" | Wrong UUID or name | Use `search` to find the correct identifier |
| "Characteristic not writable" | Trying to set a read-only characteristic | Check the writable column in the characteristics tables below |
| Values show `"nil"` | Accessory is unreachable or bridge hasn't synced | Check `reachable` field; unreachable devices return `nil` for all state values |

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
