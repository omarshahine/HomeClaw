---
description: |
  Control HomeKit smart home accessories via homeclaw-cli.
  Use when the user asks to control lights, locks, thermostats, fans, blinds,
  scenes, or check device/sensor status.
  Examples: "turn off the stairs lights", "lock the front door", "what's the temperature",
  "run the movie scene", "close the blinds", "is the garage door open"
---

# HomeKit Control

## Golden Rule: Device Map First

**ALWAYS run `homeclaw-cli device-map --json` before your first HomeKit action in a session.**

Many devices share names (e.g., "Kitchen Overhead" exists in both Kitchen and Basement). The device map gives you:
- Exact names, rooms, and zones
- `display_name` for disambiguation (room-prefixed)
- `aliases` for fuzzy matching to what the user said
- `state_summary` so you know current state before acting
- `semantic_type` to distinguish lights vs switches vs sensors

Cache the results mentally for the session. Don't re-fetch unless devices may have changed.

## Resolving What the User Means

1. Match user's words against `name`, `display_name`, `aliases`, and `room`
2. If ambiguous, prefer the device in the most likely room (main living areas > basement > outdoor)
3. If still ambiguous, ask
4. "Stairs" vs "Staircase" vs "Basement Stairs" are different devices — be precise

## Commands

```bash
# Discovery (always start here)
homeclaw-cli device-map --json          # Full device tree with aliases
homeclaw-cli device-map                 # Human-readable overview

# Control
homeclaw-cli set "<name>" power true    # On/off (switches, lights, outlets)
homeclaw-cli set "<name>" brightness 50 # Lights (0-100)
homeclaw-cli set "<name>" target_temperature 72  # Thermostat
homeclaw-cli set "<name>" target_heating_cooling auto  # HVAC mode: off/heat/cool/auto
homeclaw-cli set "<name>" lock_target_state locked     # Locks: locked/unlocked
homeclaw-cli set "<name>" target_position 100          # Blinds/shades (0=closed, 100=open)

# Read
homeclaw-cli get "<name>" --json        # Full detail on one device
homeclaw-cli list --room "Kitchen" --json  # All devices in a room
homeclaw-cli search "<query>" --json    # Search by name/room/category

# Scenes
homeclaw-cli scenes --json              # List all scenes
homeclaw-cli trigger "<scene-name>"     # Run a scene
```

## Device Categories

| Category | Controls | Key Characteristics |
|----------|----------|-------------------|
| `lightbulb` / `lighting` | Lights | `power`, `brightness`, `hue`, `saturation`, `color_temperature` |
| `switch` / `power` | Switches, smart plugs | `power` |
| `thermostat` / `climate` | HVAC | `target_temperature`, `target_heating_cooling`, `current_temperature` |
| `door_lock` | Locks | `lock_target_state` (locked/unlocked) |
| `window_covering` | Blinds, shades | `target_position` (0-100) |
| `fan` | Fans | `active`, `rotation_speed` |
| `sensor` | Temp, humidity, motion, contact, leak | Read-only |
| `security` | Cameras, garage door | `target_door_state` (open/closed) for garage |

## Important Notes

- Many "lights" are actually Lutron/Caseta switches (`category: switch`, `semantic_type: power`). They only have `power`, not `brightness`.
- Temperature values come back formatted: `"71°F"`. Set with plain numbers.
- `--json` flag on read commands gives parseable output. Always use it when you need to process results.
- Unreachable devices show `nil` for all state values.
- The socket is at `/tmp/homeclaw.sock` — if CLI fails, check that HomeClaw.app is running.

## Batch Operations

For "turn off all lights" or "lock all doors", query the device map, filter by semantic_type, then loop:

```bash
homeclaw-cli device-map --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
for home in d.get('homes', []):
    for zone in home.get('zones', []):
        for room in zone.get('rooms', []):
            for dev in room.get('devices', []):
                if dev['semantic_type'] == 'lighting' and dev.get('reachable'):
                    print(dev['name'], dev.get('display_name', ''), dev['state_summary'])
"
```

Then set each one individually.
