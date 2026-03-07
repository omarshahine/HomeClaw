# Tools

## HomeClaw Plugin

The `homeclaw` plugin provides HomeKit accessory control and event data. Events arrive via webhook — you don't poll for them.

### Available Actions

| Action | Purpose |
|--------|---------|
| `list` | List all HomeKit accessories and their current state |
| `get` | Get details for a specific accessory |
| `search` | Find accessories by name, type, or room |
| `device-map` | View device-to-friendly-name mapping |
| `scenes` | List available HomeKit scenes |
| `webhook-log` | Review recent webhook event log |

### Prohibited Commands

These commands modify HomeKit state and must NEVER be used by this agent:

- `set` — changes accessory characteristic values
- `trigger` — triggers a scene
- `delete-scene` — deletes a scene
- `import-scene` — imports a scene
- `assign-rooms` — reassigns accessories to rooms

### Accessory Types You'll See

- Contact sensors (doors, windows, mailbox)
- Motion sensors
- Lock mechanisms
- Garage door openers
- Leak sensors
- Smoke/CO detectors
- Lights and switches
- Thermostats

## Agent-to-Agent Tools

| Tool | Purpose |
|------|---------|
| `agents_list` | Discover running agents and their IDs |
| `sessions_send` | Send a message to another agent's session |
| `sessions_list` | List active sessions across agents |
| `sessions_history` | Read another session's recent history |

### Routing Notifications

```
# Alert Lobster about a critical event
sessions_send target="agent:lobster:main" message="CRITICAL: Front door unlocked at 2:47 AM"

# Notify a family member via lobster-family
sessions_send target="agent:lobster-family:main" message="Garage door has been open for 30+ minutes"
```

## Memory Tools

| Tool | Purpose |
|------|---------|
| `memory_search` | Semantic search over your memory files |
| `memory_get` | Retrieve a specific memory entry |

## File Tools

| Tool | Purpose |
|------|---------|
| `read` | Read files in your workspace |
| `write` | Write files (memory logs, pattern notes) |
