# HomeClaw Test Plan

Status: P1 + P2 implemented (2026-05-31). Phases P3–P5 remain proposed.

**P1 — L1 parse/format + pure-helper tests (landed).** The suite grew from 60 to 158
tests across 7 files, all running in the existing `swift test` CI job with no signing
infrastructure. New files: `CommandParsingTests` (parse contract for all 30 commands),
`SharedHelperTests` (`validateInput`, `parseSinceValue`, `shouldOutputJSON`),
`AutomationsHelperTests` (`formatWeekdays`, `validateTimeSpec`), `TUINodeTests`
(AccessoryNode display logic + `Ui.parseRooms`, guarded `#if !APP_STORE`). One
behavior-preserving refactor: `shouldOutputJSON` gained an injectable core so the
flag/env/TTY precedence is testable.

**P2 — DemoFixtures full mock backend (landed).** `DemoFixtures` is now a mutable
in-memory model (rooms, accessories, scenes, zones, automations) with `resetState()`,
and **22 new `isDemoMode` branches** were added to `HomeKitManager` so the previously
HomeKit-only commands work end-to-end against deterministic data: scene get/import/
update/delete, room create/rename/remove + assign, accessory rename/remove, zone
create/remove + room membership, search, device-map, and all 8 automation commands
(list/get/create/create-time/delete/enable/disable/rewire/add-condition). Every branch
is gated behind `isDemoMode`, so production behavior is untouched. Verified two ways:
(1) the Catalyst app compiles clean under Swift 6 strict concurrency with the new
branches; (2) a standalone harness drives the `DemoFixtures` model through 47
read/CRUD/not-found/reset/JSON-serializability checks — all pass. This unlocks **P3**
(the end-to-end harness that boots the demo app and drives the CLI over the socket).

## 1. Why this exists

Recent PRs added CLI features fast and tests did not keep pace. Today:

- **30 CLI command files**, ~50 socket commands. Only **2** features have any tests
  (`automations create-time`, `automations add-condition`), and those cover **argument
  parsing only** — not execution.
- **0 integration tests.** No test ever sends a command over the socket and checks the result.
- **`mcp-server/server.js`** (Node) and the **OpenClaw plugin** have no tests at all.
- **CI** builds `homeclaw-cli` + `mcp-server` and runs `swift test`, but validates no behavior.

The bugs in recent PRs (#65/#67 predicate decode, #68 socket self-heal) live in exactly the
layer that has no coverage: the socket server + HomeKit decode path.

## 2. The architecture, in terms of what is testable

```
CLI command (.swift)          SocketClient.send()          SocketServer.processRequest()      HomeKitManager
  parse + validate args  ───►  JSON over /tmp/...sock  ───►  switch(command) dispatch    ───►  HMHomeManager
  format response                                                                          └─►  DemoFixtures  ◄── HOMECLAW_DEMO=1
```

Four seams, each a different test layer:

| Layer | What runs | Needs a live app? | Needs HomeKit? | Runs in CI today? |
|-------|-----------|-------------------|----------------|-------------------|
| **L1 — CLI parse/format** | `Command.parse()`, `.validate()`, response formatting | No | No | ✅ yes (SPM test target) |
| **L2 — Socket dispatch + manager** | `SocketServer.processRequest` → `HomeKitManager` in demo mode | In-process (app target) | No (demo mode) | ❌ no (Catalyst app not built in CI) |
| **L3 — End-to-end CLI↔socket** | real `homeclaw-cli` ↔ real `HomeClaw.app` under `HOMECLAW_DEMO=1` | Yes | No (demo mode) | ❌ no (needs signed app) |
| **L4 — MCP server** | `server.js` spawning the CLI | Depends (fake CLI or demo app) | No | ❌ no |

**Crucial existing asset:** `HomeKitManager.isDemoMode` already routes ~16 socket commands
to `DemoFixtures` (homes, rooms, accessories, scenes, control). That means L2/L3 testing of
those commands is reachable **right now** with deterministic data and zero HomeKit dependency.
`DemoFixtures` does **not** yet cover: automations, triggers, config, webhooks, zones, rename,
room create/remove, device-map, events. Extending it unlocks those commands for L2/L3.

## 3. Strategy

Prioritize by **(risk of the code) × (cheapness of the test)**.

1. **L1 everywhere first** — cheap, runs in existing CI, no new infra. Covers all 30 commands'
   arg validation and the response-formatting branches. This is the bulk of the line count and
   catches the "malformed invocation" class of bug immediately.
2. **Extend `DemoFixtures`** to cover the remaining command domains (automations, config, zones,
   webhooks, triggers). This is the single highest-leverage piece of infra — it turns the demo
   app into a full mock backend.
3. **L3 end-to-end harness** — a shell/Swift harness that boots `HomeClaw.app` with
   `HOMECLAW_DEMO=1`, waits for the socket, runs `homeclaw-cli` subcommands, and asserts on
   `--json` output. This is the test that would have caught #65/#67/#68.
4. **L4 MCP server** — spawn `server.js`, drive a fake CLI (or the demo app), assert tool I/O.
5. **CI wiring** — L1 stays in the existing `swift test` job. L2/L3/L4 need a signed-app job
   (self-hosted or a signing identity in Actions) gated to run on a schedule or on `cli`-labeled PRs.

## 4. Coverage matrix (target state)

Legend: ✅ has test · 🅿️ parse-only today · ⬜ none today · → target layer

| Command (CLI) | Socket command | Today | Target | DemoFixtures work needed |
|---|---|---|---|---|
| `list` | `list_accessories` / `list_all_accessories` | ⬜ | L1 + L3 | none (exists) |
| `get` | `get_accessory` | ⬜ | L1 + L3 | none |
| `set` | `control` | ⬜ | L1 + L3 | none |
| `search` | `search` | ⬜ | L1 + L3 | none |
| `status` | `status` | ⬜ | L1 + L3 | none |
| `scenes` | `list_scenes` | ⬜ | L1 + L3 | none |
| `get-scene` | `get_scene` | ⬜ | L1 + L3 | none |
| `import-scene` | `import_scene` | ⬜ | L1 + L3 | **add scene CRUD to fixtures** |
| `update-scene` | `update_scene` | ⬜ | L1 + L3 | add scene CRUD |
| `delete-scene` | `delete_scene` | ⬜ | L1 + L3 | add scene CRUD |
| `config` | `get_config` / `set_config` | ⬜ | L1 + L2 | **add config state to fixtures** |
| `device-map` | `device_map` | ⬜ | L1 + L3 | none |
| `events` | `events` | ⬜ | L1 + L2 | add event log to fixtures |
| `triggers` | `list/add/remove/update_trigger` | ⬜ | L1 + L2 | **add trigger CRUD** |
| `webhook-log` | `webhook_log*` | ⬜ | L1 + L2 | add webhook log to fixtures |
| `automations list` | `list_automations` | ⬜ | L1 + L3 | **add automation fixtures** |
| `automations get` | `get_automation` | ⬜ | L1 + L3 | add automation fixtures |
| `automations create` | `create_automation` | ⬜ | L1 + L3 | add automation CRUD |
| `automations create-time` | `create_time_automation` | 🅿️✅ | + L3 | add automation CRUD |
| `automations add-condition` | `add_automation_condition` | 🅿️✅ | + L3 | add automation CRUD |
| `automations delete/enable/disable/rewire` | `*_automation` | ⬜ | L1 + L3 | add automation CRUD |
| `rename` (home/accessory) | `rename` | ⬜ | L1 + L2 | add rename to fixtures |
| `create-room`/`rename-room`/`remove-room` | `*_room` | ⬜ | L1 + L2 | add room CRUD |
| `create-zone`/`remove-zone`/zone membership | `*_zone` | ⬜ | L1 + L2 | **add zone model to fixtures** |
| `ui` (TUI) | n/a (local render) | ⬜ | L1 (snapshot) | none |
| `welcome` | n/a | ⬜ | L1 | none |
| MCP tools (all) | via CLI | ⬜ | L4 | inherits L3 fixtures |

## 5. Phases & effort

| Phase | Deliverable | Effort | CI |
|---|---|---|---|
| **P1** | L1 parse/format tests for all 30 commands. Extend the existing pattern in `Tests/homeclaw-cliTests/`. Factor shared response-formatting helpers so they're unit-testable without a socket. | ~1–2 days | existing job, no changes |
| **P2** | Extend `DemoFixtures` to cover automations, config, zones, triggers, webhooks, scene/room CRUD. Add a demo-mode reset hook so each test starts clean. | ~1–2 days | n/a (infra) |
| **P3** | L3 end-to-end harness: boot demo app, poll socket, run CLI subcommands, assert `--json`. Golden-file the JSON shapes. Cover the recent-PR regressions explicitly (#65/#67/#68). | ~2–3 days | new signed-app job |
| **P4** | L4 MCP tests: spawn `server.js`, assert each tool's request→CLI→response mapping. | ~1 day | new job (can reuse P3 app) |
| **P5** | CI wiring: keep L1 in `swift test`; add a gated `integration` job (self-hosted signing or scheduled) for L2–L4. Document local run in CLAUDE.md. | ~0.5 day | workflow change |

P1 + P2 are the floor and need no signing infrastructure. P3 is where the real regression
protection lives but depends on a signed build of the Catalyst app.

## 6. Open questions (decide before P3)

1. **Where does L2 run?** Adding an XCTest target to the Xcode project lets us call
   `SocketServer`/`HomeKitManager` in-process under demo mode — faster and no socket — but it
   only runs where the app builds (signing). Alternative: skip L2, do everything via L3.
   *Recommendation: do L2 as a thin Xcode unit-test target; it's cheaper than L3 per-assertion.*
2. **CI signing.** Does a self-hosted macOS runner with a signing identity exist, or do we add
   the App Store Connect API key + cert to Actions? L3/L4 can't run in CI without one.
   Fallback: L3/L4 are local-only + a nightly self-hosted run.
3. **Golden files vs. assertions.** Golden JSON files catch shape drift but are noisy on
   intentional changes. *Recommendation: assert on specific fields for behavior, golden-file
   only the large list payloads.*
4. **DemoFixtures as test fixture vs. screenshot fixture.** Today it serves App Store
   screenshots. If tests assert exact values, screenshot tweaks break tests. *Recommendation:
   keep one source of truth but make tests assert structural/behavioral invariants, not cosmetic
   strings.*

## 7. What this buys us

- Every CLI command gains arg-validation coverage that runs on every PR (P1).
- A real mock backend (`DemoFixtures`) that any future CLI feature can be tested against (P2).
- An end-to-end path that exercises the exact socket + decode layer where the last three bug-fix
  PRs landed (P3) — i.e. the next #65-class regression gets caught before merge.
- A rule going forward: **new CLI feature = L1 test always, L3 test if it changes socket I/O.**
