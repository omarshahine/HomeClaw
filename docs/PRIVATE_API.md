# HomeKit Private API: Trigger-Owned Action Sets

## Summary

When Apple's Home app creates a per-press automation on a programmable switch
(button single/double/long press → set blinds to X), the resulting `HMActionSet`
does NOT appear in the user's Scenes list. These are called **trigger-owned**
action sets — they're attached to a trigger but excluded from `home.actionSets`
enumeration. They keep the Home app's Scenes view clean.

Third-party HomeKit apps (including HomeClaw) cannot create trigger-owned action
sets with populated actions. This document records the investigation that
established this, so future tinkering doesn't redo the work.

## What works (read-side, public API)

`HMHome.triggers` and `HMTrigger.actionSets` are public properties. Trigger-owned
action sets ARE reachable through this path — they just don't appear in
`home.actionSets`.

HomeClaw's `listScenes` and `getScene` walk both `home.actionSets` AND every
`trigger.actionSets` to enumerate all action sets in a home. Trigger-owned ones
get a `"hidden": true` marker in the JSON output. Implementation:
`Sources/homeclaw/HomeKit/HomeKitManager.swift` → `allActionSets(in:)`.

`actionSet.actionSetType` returns the literal string `"HMActionSetTypeUserDefined"`
for trigger-owned sets too — the hidden behavior is purely from the daemon's
filtering of `home.actionSets`, not from a special type tag.

## What doesn't work (write-side, gated by SPI entitlement)

The HomeKit daemon (`homed`) checks the entitlement
**`com.apple.homekit.private-spi-access`** (Boolean) on the calling app for any
mutation to a trigger-owned action set. This entitlement is granted only to
Apple-signed system apps (notably `/System/Applications/Home.app`). It is NOT
in the `com.apple.developer.homekit` family and cannot be requested via Apple
Developer Program provisioning.

Confirmed by: `codesign -d --entitlements - /System/Applications/Home.app` shows
`[Key] com.apple.homekit.private-spi-access [Value] [Bool] true`.

### What we tried and what each step did

| Step | Selector | Result |
|---|---|---|
| Create trigger | `HMHome.addTrigger:completionHandler:` (public) | ✅ Persists |
| Create empty trigger-owned action set attached to trigger | `HMTrigger.addActionSetWithCompletionHandler:` (private) | ✅ Persists |
| Populate with action via public selector | `HMActionSet.addAction:completionHandler:` | ❌ "Missing entitlement for API" |
| Populate with action via private selector | `HMActionSet._addAction:completionHandler:` | ❌ "Missing entitlement for API" |
| Populate via low-level sync mutate | `HMActionSet._doAddAction:uuid:` | ⚠ Modifies in-memory `actions` array but does NOT sync to homed. After app restart, actions are gone. |

### Conclusion

The SPI gate sits inside `homed` on the persisting-write path for any action set
whose effective type is trigger-owned. It does NOT live on the framework-side
selector. Bypass strategies that work for some other private APIs do not apply:

- Mac Catalyst → same `homed`, same gate
- Developer Mode → doesn't grant SPI entitlements
- Sideloading / TestFlight / Enterprise → provisioning profiles cannot carry
  `com.apple.homekit.private-spi-access`
- `NSSelectorFromString` + `perform()` → bypasses link-time symbol scanning but
  not the daemon's runtime entitlement check

No third-party HomeKit app (Controller for HomeKit, Eve, Aqara Home, Home+,
Homepass) creates trigger-owned action sets. They all create
`HMActionSetTypeUserDefined` scenes that pollute the Scenes list. This isn't
because they haven't tried — it's because Apple has hard-locked the SPI.

## Related Apple Feedback

- **FB7775451** — "Please allow 3rd party apps to create Scenes as
  'Trigger Owned'." Filed 2020, still open with no movement as of 2026-05-17.

## Workaround for HomeClaw users who want hidden automations

Use the Apple Home app to create the automation:
1. Long-press the button accessory tile in Home app
2. Tap the press type (Single Press / Double Press / Long Press)
3. Pick "Convert To Scene" or directly add actions
4. Apple Home internally calls the SPI selector on your behalf and creates the
   trigger-owned action set

After that, HomeClaw's CLI/MCP can READ, INSPECT, MODIFY (the action set is no
longer "freshly created" — modifications via public API may or may not work,
not tested), or DELETE the trigger.

HomeClaw cannot create them from scratch. The CLI's `automations create
--action ...` will continue to create a regular visible scene attached to the
trigger.

## Why this document exists

This investigation has been done twice now (2026-05-17 by Omar + Claude). The
runtime probes, selector dumps, and entitlement check confirmation are all
captured here so the next person who thinks "what if we just call the private
API?" can read this and skip the 2 hours of digging.

Key reference points:
- Runtime selector enumeration: see git history for `/tmp/hmprobe.swift` and
  `/tmp/hmprobe2.swift` (one-off Swift probes, deleted after use).
- Open Apple feedback: FB7775451
- Memory entry: `~/.claude/projects/-Users-omarshahine-GitHub-HomeClaw/memory/private_api_hidden_action_sets.md`
