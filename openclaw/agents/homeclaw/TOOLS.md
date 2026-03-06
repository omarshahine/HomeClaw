# HomeClaw Agent Tools

## homeclaw-cli (Read-Only)

All commands connect to the HomeClaw app via Unix socket at `/tmp/homeclaw.sock`.

### Allowed Commands

| Command | Description | Example |
|---------|-------------|---------|
| `status` | Check HomeKit connection health and home info | `homeclaw-cli status` |
| `list` | List accessories with current states | `homeclaw-cli list --room Kitchen` |
| `get` | Get detailed accessory info by name or UUID | `homeclaw-cli get "Front Door Lock"` |
| `search` | Find accessories by name, type, or room | `homeclaw-cli search --type lock` |
| `device-map` | View device-to-friendly-name mapping | `homeclaw-cli device-map` |
| `scenes` | List available HomeKit scenes | `homeclaw-cli scenes` |
| `webhook-log` | Review recent webhook event log | `homeclaw-cli webhook-log --limit 50` |

### Prohibited Commands

These commands modify HomeKit state and must NEVER be used:

- `set` — changes accessory characteristic values
- `trigger` — triggers a scene
- `delete-scene` — deletes a scene
- `import-scene` — imports a scene
- `assign-rooms` — reassigns accessories to rooms

## a2a Messaging

Send messages to the main agent (Lobster) using the a2a protocol.

### Severity Levels

| Level | When to Use | Delivery |
|-------|-------------|----------|
| CRITICAL | Immediate security concern, sensor alarms | Always, immediately |
| NOTABLE | Meaningful events during waking hours | 6am-10pm only |
| AMBIENT | Routine events | Never sent — log to memory only |

### Message Format

```
Severity: CRITICAL | NOTABLE
Event: [concise description]
Context: [time, location, recent related events]
Pattern: [recognized pattern name, or "None"]
Action: [suggested response, always optional]
```

## Memory

Read and write files in the agent memory directory for pattern tracking.

- `memory/YYYY-MM-DD.md` — daily event summaries
- `memory/baseline.md` — established normal patterns
- `memory/patterns.md` — recurring multi-event sequences

Keep files concise. Summarize, don't dump raw data.
