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

HomeClaw pushes HomeKit events to [OpenClaw](https://docs.openclaw.ai/automation/webhook) via webhooks, enabling your AI assistant to react to real-world events — a door unlocking, a leak sensor triggering, or a scene activating.

### Two Endpoints: Wake vs Agent

| | `/hooks/wake` | `/hooks/agent` |
|---|---|---|
| **Purpose** | Notify the active session | Run an isolated AI agent turn |
| **Payload** | `{"text": "...", "mode": "now"}` | `{"message": "...", "name": "...", "deliver": true}` |
| **Session** | Dedicated `hook:homeclaw` session | Separate `hook:<uuid>` per event |
| **Persistence** | Persistent session, accumulates events | Persisted in its own session |
| **Timeout** | 10 seconds | 30 seconds (for LLM inference) |
| **Use for** | Lights, scenes, temperature | Door unlocks, leak sensors, security |

**Default is wake.** Upgrade individual triggers to agent for events that need AI analysis.

**Security model:** Bearer token + network isolation. Both services on `127.0.0.1` (loopback) or within a Tailnet. Each request includes `X-Request-ID` (UUID) and `X-Event-Timestamp` (ISO8601) for idempotency.

### How Events Flow

```
Home app / physical switch / Siri / manufacturer app
        │
        ▼
HomeKit (HMAccessoryDelegate push notification)
        │
        ▼
HomeClaw event logger (writes to events.jsonl)
        │
        ├── Trigger matches? ──► POST /hooks/wake or /hooks/agent
        │
        └── No trigger ──► Logged to disk only (no webhook sent)

        ▼  (trigger matched)
OpenClaw gateway validates Bearer token
        │
        ├── /hooks/wake ──► hook:homeclaw session (dedicated, persistent)
        └── /hooks/agent ──► Isolated agent turn in hook:<uuid> session
```

HomeClaw subscribes to HomeKit push notifications for all interesting characteristics. Events fire for changes from **any source** — Home app, physical switches, Siri, manufacturer apps, and the CLI.

### End-to-End Setup

#### Step 1: Configure OpenClaw

Add the `hooks` block to `~/.openclaw/openclaw.json`:

```json
"hooks": {
  "enabled": true,
  "token": "${HOMECLAW_WEBHOOK_TOKEN}",
  "defaultSessionKey": "hook:homeclaw",
  "internal": {
    "enabled": true,
    "entries": {
      "audit-logger": { "enabled": true }
    }
  }
}
```

The `defaultSessionKey` routes all wake events to a dedicated `hook:homeclaw` session instead of the main session. This prevents HomeKit noise (every light toggle, motion sensor) from polluting the main conversation context. Agent triggers (`/hooks/agent`) still create isolated sessions.

Generate a token and add it to `~/.openclaw/.env`:

```bash
# Generate
openssl rand -base64 24 | tr '+/' '-_' | tr -d '='

# Add to .env
echo 'HOMECLAW_WEBHOOK_TOKEN=<generated-token>' >> ~/.openclaw/.env
```

The gateway hot-reloads `hooks.enabled` and `hooks.token`. Restart with `openclaw gateway restart` if `.env` wasn't loaded at process start.

#### Step 2: Configure HomeClaw

```bash
homeclaw-cli config --webhook-url "http://127.0.0.1:18789" \
                    --webhook-token "<same-token>" \
                    --webhook-enabled true
```

Or use HomeClaw Settings > Webhook (the Generate button creates a token — copy it to OpenClaw's `.env`).

#### Step 3: Create Triggers

Open HomeClaw Settings > Webhook. Check the scenes and accessories you want to fire webhooks. Start with security accessories (locks, garage doors) and a few lights to verify.

Triggers can also be managed via the socket:

```bash
# List current triggers
echo '{"command":"list_triggers"}' | nc -U ~/Library/Group\ Containers/group.com.shahine.homeclaw/homeclaw.sock

# Add a trigger
echo '{"command":"add_trigger","args":{"label":"Garage Door","accessory_id":"<uuid>"}}' | nc -U ~/Library/Group\ Containers/group.com.shahine.homeclaw/homeclaw.sock
```

#### Step 4: Verify

```bash
# Check webhook health
homeclaw-cli status

# Toggle a light from the Home app, then check
homeclaw-cli events --since 5m

# Check delivery logs
log show --predicate 'process == "HomeClaw" AND category == "webhook"' --last 5m --style compact
```

Look for a `System:` line in the OpenClaw TUI.

### Upgrading Triggers to Agent Mode

The Settings UI creates triggers with **wake** behavior. Upgrade specific triggers to **agent** mode via the socket for smarter event handling:

```bash
# Upgrade an existing trigger to agent mode
echo '{"command":"update_trigger","args":{
  "id":"<trigger-uuid>",
  "action":"agent",
  "agent_prompt":"The front door was unlocked. Check recent activity and alert me if unexpected.",
  "agent_name":"HomeClaw Security",
  "agent_deliver":true
}}' | nc -U ~/Library/Group\ Containers/group.com.shahine.homeclaw/homeclaw.sock
```

Or create an agent trigger directly:

```bash
echo '{"command":"add_trigger","args":{
  "label":"Front door unlocked",
  "accessory_id":"<lock-uuid>",
  "characteristic":"lock_target_state",
  "value":"unlocked",
  "action":"agent",
  "agent_prompt":"The front door was unlocked. Analyze recent activity and determine if this is expected.",
  "agent_name":"HomeClaw Security",
  "agent_deliver":true
}}' | nc -U ~/Library/Group\ Containers/group.com.shahine.homeclaw/homeclaw.sock
```

**Tip:** Set `agent_deliver: true` on security triggers. This marks them as **critical** — they bypass the circuit breaker and always attempt delivery, even when the circuit is tripped from other failures.

### Common Trigger Patterns

| Scenario | Action | wake_mode | agent_deliver | Why |
|----------|--------|-----------|---------------|-----|
| Door unlocked | `agent` | — | `true` | Security — AI analyzes, bypasses circuit breaker |
| Garage door opened | `agent` | — | `true` | Security — AI analyzes, bypasses circuit breaker |
| Leak sensor triggered | `agent` | — | `true` | Critical — AI should alert immediately |
| Scene "Good Night" | `wake` | `now` | — | Informational — notify immediately |
| Light toggled | `wake` | (default) | — | Ambient — batched with next heartbeat |
| Temperature changed | `wake` | (default) | — | Ambient — batched with next heartbeat |
| Motion detected | `wake` | (default) | — | Awareness — batched, no AI analysis |

### Tips

- **Default wake mode is `next-heartbeat`.** Wake triggers batch events into the next heartbeat cycle. Set `wake_mode: "now"` explicitly on triggers that need immediate delivery (e.g., scene triggers where you want instant feedback).
- **Start with wake, promote to agent.** Get wake working first, then selectively upgrade security triggers. Agent calls are heavier (30s timeout, separate session, LLM inference cost).
- **Use `agent_deliver: true` sparingly.** It marks triggers as circuit-breaker-critical. Reserve it for events that must never be silently dropped (door unlocks, leaks). Overusing it defeats the circuit breaker's protection.
- **Triggers are additive.** Multiple triggers can match the same event (e.g., an accessory trigger + a characteristic trigger). Each matched trigger fires its own webhook.
- **No catch-all.** Only events matching a configured trigger fire webhooks. Untriggered events are logged to disk but not pushed to the gateway.
- **Scene triggers match by name or UUID.** Use scene UUID for precision, scene name for convenience (case-insensitive).
- **Characteristic + value filtering.** A trigger with `characteristic: "lock_current_state"` and `value: "unlocked"` only fires on unlock, not on lock. Omit `value` to fire on any state change.
- **Check `homeclaw-cli status --json`** for webhook health: `circuit_state`, `last_success`, `last_failure`, `total_dropped`.

### Circuit Breaker

| State | After | Behavior | Recovery |
|-------|-------|----------|----------|
| Normal | — | All webhooks delivered | — |
| Soft Open | 5 failures | Non-critical paused 5 min | Auto-resumes |
| Hard Open | 3 soft trips | All non-critical stopped | Toggle webhook off→on in Settings |

Critical triggers (`agent_deliver: true`) always bypass.

### Trigger Fields Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `action` | string | `"wake"` | `"wake"` or `"agent"` — which endpoint receives the event |
| `wake_mode` | string | `"next-heartbeat"` | `"now"` (immediate) or `"next-heartbeat"` (batched, default) |
| `agent_prompt` | string | event text | Custom prompt for the agent (falls back to formatted event text) |
| `agent_id` | string | — | Route to a specific OpenClaw agent by ID |
| `agent_name` | string | `"HomeClaw"` | Human label shown in agent responses |
| `agent_deliver` | bool | — | Send the agent's response to a messaging channel |

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
