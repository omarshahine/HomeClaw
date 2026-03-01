---
description: |
  Control HomeKit smart home accessories and view home events via homeclaw-cli.
  Use when the user asks to control lights, locks, thermostats, fans, blinds,
  scenes, check device/sensor status, or view recent home activity/events.
  Examples: "turn off the stairs lights", "lock the front door", "what's the temperature",
  "run the movie scene", "close the blinds", "is the garage door open",
  "what happened at home today", "when was the front door last unlocked"
---

# HomeKit Control

## Golden Rule: Device Map First

**Before your first HomeKit action in a session, read `memory/homekit-device-map.json`.**

This compact device map has every device as a flat list with `display_name`, `id` (UUID), `room`, `type` (semantic category), `controls` (writable characteristics), and `state`. It's optimized for fast LLM scanning and disambiguation.

**Refresh the cache** periodically or when devices may have changed:
```bash
homeclaw-cli device-map --format agent -o memory/homekit-device-map.json
```

## Resolving What the User Means

1. Match user's words against `display_name` and `room` from the cached map
2. **Use `type` to disambiguate** — `lighting` devices support brightness; `power` devices are on/off only. A "Closet Light" with `type: power` cannot dim.
3. If ambiguous, prefer the device in the most likely room (main living areas > bedrooms > outdoor)
4. If still ambiguous, ask
5. **Use UUIDs for control when names collide** — many devices share names (9 "Overhead" lights across rooms). Use `display_name` for reading, `id` for `set` commands
6. **Check `controls` before sending a command** — if `brightness` isn't in `controls`, don't try to set it
7. **If no match found, refresh the cache first** — devices may have been added/renamed:
   ```bash
   homeclaw-cli device-map --format agent -o memory/homekit-device-map.json
   ```
   Then retry the match. Only tell the user "device not found" if it's still missing after refresh.

## Commands

```bash
# Discovery
homeclaw-cli device-map --format agent   # LLM-optimized flat list (default cache format)
homeclaw-cli device-map --format json      # Full detail with aliases, manufacturer
homeclaw-cli device-map --format md        # Markdown tables by room
homeclaw-cli search "<query>" --json       # Search by name/room/category
homeclaw-cli get "<name-or-uuid>" --json   # Full detail on one device
homeclaw-cli list --room "Kitchen" --json  # All devices in a room

# Control — use UUID when name is ambiguous
homeclaw-cli set "<name-or-uuid>" power true           # On/off
homeclaw-cli set "<name-or-uuid>" brightness 50        # Lights (0-100)
homeclaw-cli set "<name-or-uuid>" target_temperature 72 # Thermostat
homeclaw-cli set "<name-or-uuid>" target_heating_cooling auto  # HVAC: off/heat/cool/auto
homeclaw-cli set "<name-or-uuid>" lock_target_state locked     # Locks: locked/unlocked
homeclaw-cli set "<name-or-uuid>" target_position 100          # Blinds (0=closed, 100=open)

# Scenes
homeclaw-cli scenes --json              # List all scenes
homeclaw-cli trigger "<scene-name>"     # Run a scene

# Export to file (any format)
homeclaw-cli device-map --format agent -o memory/homekit-device-map.json
homeclaw-cli device-map --format md -o device-map.md
```

## Device Types and What They Accept

The `type` field in the compact map tells you what a device IS. The `controls` array tells you exactly what you CAN set. Key distinctions:

| Type | What It Is | Typical Controls |
|------|-----------|-----------------|
| `lighting` | Dimmable light | `power`, `brightness`, sometimes `hue`, `saturation`, `color_temperature` |
| `power` | On/off switch or smart plug | `power` only — **no brightness** |
| `climate` | Thermostat, heater, fireplace | `target_temperature`, `target_heating_cooling` (off/heat/cool/auto) |
| `door_lock` | Lock | `lock_target_state` (locked/unlocked) |
| `window_covering` | Blinds, shades | `target_position` (0=closed, 100=open) |
| `sensor` | Temp, humidity, motion, contact, leak | Read-only — no writable controls |
| `security` | Cameras, water shutoff | Varies: `active`, `power` |

**Critical**: A device named "Closet Light" or "Under Cabinet" with `type: power` is a relay switch. Sending `brightness 50` will fail. Always check `controls` first.

## Event Log

HomeClaw logs all HomeKit events (characteristic changes, scene triggers, control actions) to disk. Query the event log to understand what happened recently:

```bash
# Recent events (default: last 50)
homeclaw-cli events --json

# Events from the last hour
homeclaw-cli events --since 1h --json

# Only characteristic changes (e.g. lights turning on/off)
homeclaw-cli events --type characteristic_change --json

# Last 200 events
homeclaw-cli events --limit 200 --json
```

Event types: `characteristic_change`, `scene_triggered`, `accessory_controlled`, `homes_updated`

Use events to answer questions like "what changed recently?", "when was the front door last unlocked?", or "what scenes were triggered today?".

## Webhook Setup

HomeClaw can push events to OpenClaw via two endpoints:

- **`/hooks/wake`** — Lightweight text notification to the active session. The session sees "something happened" and can decide whether to act. Best for ambient events (scene triggers, temperature changes).
- **`/hooks/agent`** — Runs an isolated AI agent turn that processes the event and can take action. Best for security events (door unlocked, garage opened) where you want the AI to analyze and potentially alert you.

### Basic Setup (Wake Events)

Configure the webhook with a **base URL** (no endpoint path — HomeClaw appends `/hooks/wake` or `/hooks/agent` automatically):

```bash
homeclaw-cli config --webhook-url "http://127.0.0.1:18789" \
                    --webhook-token "shared-secret" \
                    --webhook-enabled true
```

Once enabled, all HomeKit events are POSTed to `/hooks/wake` as `{"text": "...", "mode": "now"}`. Use the Webhook tab in HomeClaw Settings to select which scenes and accessories trigger webhooks.

### Per-Trigger Agent Routing

Individual triggers can be promoted to agent routing via the socket `update_trigger` command. The UI creates triggers with default wake behavior; upgrade specific triggers to agent mode for smarter handling:

```json
{"command": "update_trigger", "args": {
  "id": "<trigger-uuid>",
  "action": "agent",
  "agent_prompt": "The front door was just unlocked. Check recent door activity and alert me if this is unexpected.",
  "agent_name": "HomeClaw Security",
  "agent_deliver": true
}}
```

Or create an agent trigger directly:

```json
{"command": "add_trigger", "args": {
  "label": "Front door unlocked",
  "accessory_id": "<lock-uuid>",
  "characteristic": "lock_target_state",
  "value": "unlocked",
  "action": "agent",
  "agent_prompt": "The front door was unlocked. Analyze recent activity and determine if this is expected.",
  "agent_name": "HomeClaw Security",
  "agent_deliver": true
}}
```

### Common Trigger Patterns

| Scenario | Action | Wake Mode | Why |
|----------|--------|-----------|-----|
| Door unlocked | `agent` | `now` | Security — AI should analyze context |
| Garage door opened | `agent` | `now` | Security — AI should analyze context |
| Leak sensor triggered | `agent` + `deliver` | `now` | Critical — AI should alert immediately |
| Scene "Good Night" | `wake` | `now` | Informational — just notify the session |
| Temperature changed | `wake` | `next-heartbeat` | Ambient — batch with other events |
| Motion detected | `wake` | `now` | Awareness — don't need AI analysis |

### Trigger Fields Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `action` | string | `"wake"` | `"wake"` or `"agent"` — which endpoint receives the event |
| `wake_mode` | string | `"now"` | `"now"` or `"next-heartbeat"` — delivery timing |
| `agent_prompt` | string | event text | Custom prompt for the agent (falls back to formatted event text) |
| `agent_id` | string | — | Route to a specific OpenClaw agent by ID |
| `agent_name` | string | `"HomeClaw"` | Human label shown in agent responses |
| `agent_deliver` | bool | — | Send the agent's response to a messaging channel |

## Important Notes

- Temperature values come back formatted: `"71F"`. Set with plain numbers.
- `--json` on read commands gives parseable output. Always use it when processing results.
- Unreachable devices have `"unreachable": true` in the compact map.
- If CLI fails with "HomeClaw is not running", the app needs to be launched first.

## Batch Operations

The compact map is flat — no nested traversal needed:

```bash
# Find all reachable lights
python3 -c "
import json
d = json.load(open('memory/homekit-device-map.json'))
for dev in d['devices']:
    if dev['type'] == 'lighting' and not dev.get('unreachable'):
        print(dev['id'], dev['display_name'], dev['state'])
"
```

Then `homeclaw-cli set "<uuid>" power false` for each.
