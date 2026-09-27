# ADR 0001: Manage Home app accessory groups as HomeKit service groups

- **Status:** Proposed
- **Date:** 2026-09-27
- **Issue:** #134 (builds on #132 / #133)

## Context

The Home app's **Group with Other Accessories** turns several accessories into one tile that controls them together and is one target for Siri. Users with bridged multi-gang hardware (e.g. an Aqara Dual Relay T2 on a Hub M3) regroup dozens of tiles by hand after every re-pair. HomeClaw can't read or change groups: `list`, `get` and `device-map` show only individual accessories.

Two different things look like "grouping" in the Home app and are easy to confuse:

1. **Multi-service accessory tiles.** A dual relay is one `HMAccessory` with two `Switch` services. The Home app's "show as separate tiles" toggle only changes layout. No public API reads or writes it, and it isn't a group.
2. **Accessory groups.** Named sets that the Home app shows as one tile. These are what users mean by "group", and they're what this ADR covers.

## Decision

Treat a Home app accessory group as an `HMServiceGroup` and manage it only through the public HomeKit API:

| Operation | API |
|---|---|
| List | `HMHome.serviceGroups`, `HMServiceGroup.services` |
| Create | `HMHome.addServiceGroup(withName:)` then `HMServiceGroup.addService(_:)` per member |
| Add / remove members | `HMServiceGroup.addService(_:)` / `removeService(_:)` |
| Rename | `HMServiceGroup.updateName(_:)` |
| Delete | `HMHome.removeServiceGroup(_:)` |

All of these are public and available on Mac Catalyst 14+; Apple's documentation describes exactly this use ("a set of lights … as 'Desk Lamps' … visible to Siri").

Rules HomeClaw applies on top of the raw API:

- **Members are services.** An accessory name or UUID resolves to its one groupable service. If there are several, the call fails and lists their service UUIDs; it never guesses. A service UUID picks one gang of a multi-gang accessory. This reuses the service-selection code from #133.
- **Only kinds the Home app groups.** Members must be a light, switch, outlet, fan, or window covering. Buttons, sensors, locks, cameras, climate and media are rejected even with `allow_mixed`: the Home app never builds such groups, so how it would render one is unspecified. Supplementary services (battery, accessory information, labels, a blind's slats) are never members.
- **One kind per group by default.** The Home app only groups one kind (lights with lights), but the API doesn't enforce it. HomeClaw rejects a mixed group unless `allow_mixed` is set. A switch or outlet with Display As `light` / `fan` counts as that kind; an association to any other type (set by another app) is ignored for this.
- **No guessing, no partial state.** Two groups with the same name make a by-name call fail and list their UUIDs. Create rolls back (removes the new group) if HomeKit rejects a member; if the rollback also fails, the error says so and gives the UUID to delete. Add/remove report how many operations landed before a rejection, and remove reports `group_deleted` if HomeKit dropped the emptied group. Already-present or absent members are skipped and reported, not treated as errors.
- **Device filter.** A group is visible only if the filter allows every member's accessory. Hidden groups are left out of listings (only counted in `hidden_groups`, never named) and are "not found" to rename, edit and delete, so a filtered client can't see or change a group that reaches past its filter. New members must be on allowed accessories.
- **Surfaces.** Socket commands `list_groups`, `create_group`, `add_to_group`, `remove_from_group`, `rename_group`, `delete_group`; CLI `homeclaw-cli groups …`; MCP `homekit_manage` actions of the same names; OpenClaw `homekit_groups` (read-only) and `homekit_manage_group` (optional, side-effecting). The loopback HTTP MCP transport stays read-only and doesn't expose them, since `homekit_manage` isn't in its allowlist.

## Alternatives considered

- **Homebridge / Home Assistant virtual accessory.** A bridge can expose one "combined" accessory that fans out to several devices. That adds a dependency and a second source of truth, and it isn't a Home app group. Rejected as HomeClaw's approach; users can still do it themselves.
- **Scenes.** One action for many devices, but a scene has no on/off state, isn't a tile per room, and isn't what "group" means in the Home app. Rejected.
- **Control groups in HomeClaw (`set` on a group).** Useful later, but once a group exists the Home app and Siri already control it as one. Deferred to keep the first change reviewable.
- **Mirror the raw API with no kind check.** Rejected: a mixed group is something the Home app itself never creates, so its rendering is unspecified. Kept behind `allow_mixed` for users who want it.
- **Private SPI.** Not needed. Unlike trigger-owned action sets (`docs/PRIVATE_API.md`), nothing here is entitlement-gated.

## Consequences

- Agents can finish the post-re-pair cleanup (names, rooms, Display As, groups) without the Home app.
- Groups created by other apps (Home app, Controller, Home+) show up in `groups`, and HomeClaw can edit them. `delete` removes a user's Home app group, so it supports `--dry-run` and never touches the member accessories.
- CI can't exercise HomeKit (unsigned, no provisioning), so the HomeKit calls are covered by review and the pure rules (kinds, mixing, argument validation) by unit tests.
- HomeClaw doesn't observe `HMHomeDelegate` group callbacks (nor room or zone ones, a gap that predates this). Groups changed in the Home app are picked up on the next `groups` call, since `home.serviceGroups` is live, but nothing is pushed proactively.

## Verification still needed on real hardware

1. **Mapping:** existing Home app groups appear in `homeclaw-cli groups`. This is the cheapest proof that Home app groups are `HMServiceGroup`s.
2. **Parity:** a group created with `groups create` renders as one tile in the Home app and responds to Siri.
3. **Kinds:** a relay gang with Display As `light` grouped with bulbs behaves like a Home app light group.
4. **Rollback:** a HomeKit rejection during create leaves no empty group behind.
5. **Emptying:** whether HomeKit deletes a group when its last member is removed (reported as `group_deleted` either way).

If (2) shows that API-created groups render differently from Home app ones, record why here and narrow the create/add path, keeping list, rename and delete.
