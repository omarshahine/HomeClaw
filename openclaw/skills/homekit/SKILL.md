---
name: homekit
description: |
  Control HomeKit smart home accessories and view home events via homeclaw-cli.
  Use when the user asks to control lights, locks, thermostats, fans, blinds,
  scenes, check device/sensor status, or view recent home activity/events.
  Examples: "turn off the stairs lights", "lock the front door", "what's the temperature",
  "run the movie scene", "close the blinds", "is the garage door open",
  "what happened at home today", "when was the front door last unlocked"
metadata:
  openclaw:
    emoji: house
    os: ["darwin"]
    homepage: https://github.com/omarshahine/HomeClaw
    requires:
      bins: ["homeclaw-cli"]
    install:
      - kind: download
        id: homeclaw
        label: "Install HomeClaw.app from TestFlight or build from source"
        url: https://github.com/omarshahine/HomeClaw
        bins: ["homeclaw-cli"]
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
homeclaw-cli get-scene "<name>" --json  # Full detail: all actions (accessory, room, characteristic, value)
homeclaw-cli trigger "<scene-name>"     # Run a scene
homeclaw-cli import-scene scene.json --dry-run   # Preview scene import
homeclaw-cli import-scene scene.json              # Create scene from JSON
homeclaw-cli delete-scene "<name>" --dry-run      # Preview deletion
homeclaw-cli delete-scene "<name>"                # Delete a scene

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

## Webhook Integration

HomeClaw pushes HomeKit events to [OpenClaw](https://docs.openclaw.ai/automation/webhook) via webhooks, enabling a dedicated AI agent to observe, classify, and react to real-world events — a door unlocking, a leak sensor triggering, or a scene activating.

> **Known Issue:** OpenClaw 2026.3.1/2026.3.2 has a bug where `/hooks/wake` silently drops events ([#33271](https://github.com/openclaw/openclaw/issues/33271)). HomeClaw uses **mapped webhooks** (`/hooks/homeclaw`) which route through `hooks.mappings` and are **not affected**.

### Mapped Webhook Architecture

HomeClaw always POSTs to a single mapped endpoint: `/hooks/homeclaw` (configurable via `webhookEndpoint` in `config.json`). OpenClaw's `hooks.mappings` config resolves the `"homeclaw"` key and routes the event to the dedicated HomeClaw agent.

This means HomeClaw doesn't need to know about `agentId`, `channel`, `deliver`, `model`, or `sessionKey` — all routing intelligence lives in the OpenClaw config. HomeClaw just sends events; OpenClaw decides what to do with them.

**Payload:** `{"text": "[label] event text", "mode": "now|next-heartbeat"}` with `Authorization: Bearer <token>`, `X-Request-ID` (UUID), and `X-Event-Timestamp` (ISO8601) headers.

### How Events Flow

```
Home app / physical switch / Siri / manufacturer app
        |
        v
HomeKit (HMAccessoryDelegate push notification)
        |
        v
HomeClaw event logger (writes to events.jsonl)
        |
        +-- Battery event? --> Logged to disk only (never sent via webhook)
        |
        +-- Trigger matches? --> POST /hooks/homeclaw
        |
        +-- No trigger --> Logged to disk only (no webhook sent)

        v  (trigger matched)
OpenClaw gateway validates Bearer token
        |
        v
hooks.mappings resolves "homeclaw"
        |
        v
HomeClaw Agent (dedicated)
        +-- Classifies: CRITICAL / NOTABLE / AMBIENT
        +-- If CRITICAL/NOTABLE: a2a message to main agent (Lobster)
        +-- If AMBIENT: log to agent memory only
```

HomeClaw subscribes to HomeKit push notifications for all interesting characteristics. Events fire for changes from **any source** — Home app, physical switches, Siri, manufacturer apps, and the CLI.

### Dedicated HomeClaw Agent

A dedicated HomeClaw agent receives all webhook events and acts as an intelligent filter between your smart home and your main AI assistant:

- **Event classification** — categorizes each event as CRITICAL (immediate alert), NOTABLE (worth reporting), or AMBIENT (log only)
- **Pattern correlation** — correlates sequences of events (e.g., garage door + front door = arrival)
- **Memory building** — learns your home's patterns over time (typical schedules, normal behaviors)
- **Read-only** — the agent never controls devices, only observes and reports

**Workspace files** live in `openclaw/agents/homeclaw/`:

| File | Purpose |
|------|---------|
| `AGENTS.md` | Agent registration and capabilities |
| `IDENTITY.md` | Agent persona and behavioral guidelines |
| `SOUL.md` | Event classification rules and triage logic |
| `TOOLS.md` | Available tools (read-only HomeKit queries via homeclaw-cli) |

**Install the agent workspace:**

```bash
openclaw agents install homeclaw /path/to/openclaw/agents/homeclaw
```

### OpenClaw Configuration

Add the `hooks` block with a `mappings` entry to `~/.openclaw/openclaw.json`:

```json
"hooks": {
  "enabled": true,
  "token": "${HOMECLAW_WEBHOOK_TOKEN}",
  "mappings": {
    "homeclaw": {
      "agentId": "homeclaw",
      "sessionKey": "hook:homeclaw",
      "deliver": true,
      "channel": "last",
      "allowUnsafeExternalContent": true
    }
  },
  "internal": {
    "enabled": true,
    "entries": {
      "audit-logger": { "enabled": true }
    }
  }
}
```

| Field | Purpose |
|-------|---------|
| `agentId` | Routes to the dedicated HomeClaw agent |
| `sessionKey` | All events share a persistent `hook:homeclaw` session |
| `deliver` | Agent responses are delivered to a messaging channel |
| `channel` | `"last"` uses the most recent active channel |
| `allowUnsafeExternalContent` | Permits HomeKit event text in agent prompts |

The `mappings` approach replaces the old `defaultSessionKey` + per-trigger `action` model. All routing decisions live in OpenClaw config, not in HomeClaw triggers.

### End-to-End Setup

#### Step 1: Install the Agent Workspace

```bash
openclaw agents install homeclaw /path/to/openclaw/agents/homeclaw
```

Verify the agent is registered:

```bash
openclaw agents list
```

#### Step 2: Configure OpenClaw Hooks + Mappings

Add the `hooks` block (shown above) to `~/.openclaw/openclaw.json`.

Generate a token and add it to `~/.openclaw/.env`:

```bash
# Generate a secure token
openssl rand -base64 24 | tr '+/' '-_' | tr -d '='

# Add to .env
echo 'HOMECLAW_WEBHOOK_TOKEN=<generated-token>' >> ~/.openclaw/.env
```

Restart the gateway: `openclaw gateway restart`

#### Step 3: Configure HomeClaw Webhook

```bash
homeclaw-cli config --webhook-url "http://127.0.0.1:18789" \
                    --webhook-token "<same-token>" \
                    --webhook-enabled true
```

Or use HomeClaw Settings > Webhook. Toggle Enable, enter the base URL, and paste the token.

The `webhookEndpoint` defaults to `/hooks/homeclaw`. HomeClaw appends this to your base URL automatically.

#### Step 4: Create Triggers

Open HomeClaw Settings > Webhook. Check the scenes and accessories you want to fire webhooks. Start with security accessories (locks, garage doors, leak sensors) and a few lights to verify.

Triggers can also be managed via the CLI:

```bash
# List current triggers
homeclaw-cli triggers

# Add a trigger for all state changes on an accessory
homeclaw-cli triggers add --label "Garage Door" --accessory-id "<uuid>"

# Add a trigger for a specific characteristic only
homeclaw-cli triggers add --label "Mailbox Open" --accessory-id "<uuid>" --characteristic contact_state

# Update a trigger's delivery mode
homeclaw-cli triggers update "<trigger-id>" --wake-mode now

# Remove a trigger
homeclaw-cli triggers remove "<trigger-id>"
```

> **Note:** Battery-related characteristics (`battery_level`, `low_battery`) are automatically excluded from webhooks. They are still logged to the event log and cached for status queries, but never fire webhook triggers.

#### Step 5: Verify

```bash
# Check webhook health
homeclaw-cli status

# Toggle a light from the Home app, then check
homeclaw-cli events --since 5m

# Check delivery logs
log show --predicate 'process == "HomeClaw" AND category == "webhook"' --last 5m --style compact
```

Look for a `System:` line in the OpenClaw TUI, or check that the HomeClaw agent session (`hook:homeclaw`) shows incoming events.

### Scenario Cookbook

#### Arrival Detection (Garage + Front Door Sequence)

Create triggers for both the garage door and front door. The HomeClaw agent correlates the sequence — garage opens, then front door unlocks within minutes — and reports an arrival to the main agent.

```bash
homeclaw-cli triggers add --label "Garage Door" --accessory-id "<garage-uuid>"
homeclaw-cli triggers add --label "Front Door" --accessory-id "<lock-uuid>" --characteristic lock_current_state
```

The agent sees both events in its persistent session and recognizes the arrival pattern.

#### Suspicious Unlock Alert (Door Unlocked at 2am)

The HomeClaw agent classifies door unlocks by time of day. An unlock at 2am is CRITICAL; the same unlock at 6pm is NOTABLE. No special trigger config needed — the agent's classification logic handles it.

```bash
homeclaw-cli triggers add --label "Front Door" --accessory-id "<lock-uuid>" --characteristic lock_current_state --value unlocked
```

#### Water Leak Emergency

Leak sensors should always fire immediately. The agent classifies any leak event as CRITICAL and sends an a2a alert to the main agent right away.

```bash
homeclaw-cli triggers add --label "Kitchen Leak" --accessory-id "<leak-uuid>" --characteristic leak_detected --wake-mode now
```

#### Mailbox Opened

A contact sensor on the mailbox fires when opened. The agent classifies this as NOTABLE and reports it.

```bash
homeclaw-cli triggers add --label "Mailbox" --accessory-id "<mailbox-uuid>" --characteristic contact_state
```

#### Bedtime Pattern (Good Night Scene)

Scene triggers capture when someone runs the Good Night scene. The agent logs it as AMBIENT and uses it to learn bedtime patterns over time.

```bash
homeclaw-cli triggers add --label "Good Night" --scene-name "Good Night" --wake-mode now
```

#### Daily Activity Summary

The agent builds a daily summary from all events in its session. No special trigger config — just ensure your key accessories have triggers enabled. The agent can be prompted to summarize via a2a from the main agent.

### Trigger Fields Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `wake_mode` | string | `"next-heartbeat"` | `"now"` (immediate) or `"next-heartbeat"` (batched, default) |
| `label` | string | — | Human-readable name shown in webhook payload |
| `accessory_id` | string | — | UUID of the accessory to watch |
| `characteristic` | string | — | Specific characteristic to filter (omit for all) |
| `value` | string | — | Only fire when characteristic equals this value |
| `scene_name` | string | — | Scene name to watch (alternative to accessory triggers) |
| `critical` | bool | `false` | Bypasses circuit breaker when `true` |

> **Deprecated fields (removed):** `action`, `agent_id`, `agent_prompt`, `agent_name`, `agent_deliver`. These are no longer needed — all routing is handled by OpenClaw's `hooks.mappings` config.

### Circuit Breaker

| State | After | Behavior | Recovery |
|-------|-------|----------|----------|
| Normal | — | All webhooks delivered | — |
| Soft Open | 5 failures | Non-critical paused 5 min | Auto-resumes |
| Hard Open | 3 soft trips | All non-critical stopped | Toggle webhook off/on in Settings |

Critical triggers (`critical: true`) always bypass the circuit breaker.

### Tips

- **Default delivery mode is `next-heartbeat`.** Events batch into the next heartbeat cycle. Set `wake_mode: "now"` on triggers that need immediate delivery (leak sensors, door locks, scene triggers).
- **Start small.** Enable triggers for a few key accessories first. Verify events appear in the HomeClaw agent session before adding more.
- **Use `critical: true` sparingly.** It bypasses the circuit breaker. Reserve it for events that must never be silently dropped (leaks, security events). Overusing it defeats the circuit breaker's protection.
- **Triggers are additive.** Multiple triggers can match the same event (e.g., an accessory trigger + a characteristic trigger). Each matched trigger fires its own webhook.
- **No catch-all.** Only events matching a configured trigger fire webhooks. Untriggered events are logged to disk but not pushed.
- **Scene triggers match by name or UUID.** Use scene UUID for precision, scene name for convenience (case-insensitive).
- **Characteristic + value filtering.** A trigger with `characteristic: "lock_current_state"` and `value: "unlocked"` only fires on unlock, not on lock. Omit `value` to fire on any state change.
- **Check `homeclaw-cli status --json`** for webhook health: `circuit_state`, `last_success`, `last_failure`, `total_dropped`.
- **The agent is read-only.** It observes and reports but never controls devices. All device control goes through the main agent or direct CLI commands.

## Agent-Friendly CLI

The CLI follows [AI-agent best practices](https://justin.poehnelt.com/posts/rewrite-your-cli-for-ai-agents/):

- **Auto-JSON**: When stdout is not a TTY (piped or called by an agent), all commands output JSON automatically — no `--json` flag needed.
- **`OUTPUT_FORMAT=json`**: Set this environment variable to force JSON output in all contexts.
- **`--dry-run` on mutations**: `set --dry-run` validates the accessory, characteristic, and value without writing to the device. `delete-scene --dry-run` confirms the scene exists without deleting.
- **Input validation**: Control characters (ASCII < 0x20) are rejected from all string arguments to defend against hallucinated inputs.

```bash
# Dry run: validate without actuating
homeclaw-cli set "Front Door" lock_target_state locked --dry-run

# Force JSON from any context
OUTPUT_FORMAT=json homeclaw-cli status
```

## Important Notes

- Temperature values come back formatted: `"71F"`. Set with plain numbers.
- `--json` on read commands gives parseable output. Always use it when processing results.
- Unreachable devices have `"unreachable": true` in the compact map.
- If CLI fails with "HomeClaw is not running", the app needs to be launched first.
- On-disk event log: `~/Library/Containers/com.shahine.homeclaw/Data/Library/Application Support/HomeClaw/events.jsonl`
- HomeClaw subscribes to HomeKit push notifications for all interesting characteristics on reachable accessories. Both Home app toggles and physical/external changes fire `characteristic_change` events.

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
