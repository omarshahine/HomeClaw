# HomeClaw Privacy Policy

**Last updated: May 8, 2026**

HomeClaw is a Mac app that exposes Apple HomeKit accessories through a CLI, an MCP server, and plugins for Claude Code and OpenClaw. This privacy policy explains how HomeClaw handles your data.

## Short version

HomeClaw collects nothing. All HomeKit data stays on your Mac. There is no analytics, no telemetry, and no HomeClaw account.

## What HomeClaw accesses

- **HomeKit data on your Mac.** HomeClaw uses Apple's HomeKit framework to read your homes, rooms, accessories, scenes, and automations. This data lives in your local HomeKit database (managed by macOS via your iCloud account) and is read on demand from the device.
- **System resources.** HomeClaw runs as a Mac Catalyst app with a native menu bar. It listens on a local Unix domain socket (`/tmp/homeclaw.sock`) so the bundled CLI, MCP server, and OpenClaw plugin can talk to it. Nothing on this socket leaves your Mac.

## What HomeClaw does NOT collect

- We do not collect or transmit any HomeKit data.
- We do not collect device identifiers, IP addresses, or hardware information.
- We do not collect crash reports, analytics, or telemetry.
- We do not require an account, login, or any registration.
- We do not use any third-party SDKs that collect data.

## Webhooks (optional)

HomeClaw can be configured to push HomeKit events to a webhook endpoint that **you specify and control** (for example, an OpenClaw instance running on your own infrastructure). HomeClaw never sends events to any endpoint without explicit configuration. You are responsible for the privacy posture of any webhook destination you configure.

## GitHub stars (optional)

The one-time About note uses a count of completed actions stored on your Mac.
No action details or use counts are sent to GitHub. Mac App Store builds only
open the public project page when you click the star button. Local builds can
check whether you already starred the project when Settings is active, and
send a star request if you click the button, using your existing GitHub CLI
login. HomeClaw does not read or store its credentials.

## App Store Connect API key & TestFlight

If you participate in the HomeClaw TestFlight beta program, Apple's standard TestFlight privacy policy applies. HomeClaw itself does not transmit any additional information beyond what TestFlight requires.

## Open source

HomeClaw is MIT-licensed open source software. You can review the source code at <https://github.com/omarshahine/HomeClaw> to verify exactly what HomeClaw does.

## Contact

For privacy questions, open an issue at <https://github.com/omarshahine/HomeClaw/issues>.
