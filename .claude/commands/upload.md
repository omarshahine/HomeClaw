---
description: Archive, upload, and submit to external TestFlight (full loop with monitor)
allowed-tools: Bash(scripts/release.sh *), Bash(TF_CHANGELOG=* scripts/release.sh *), Bash(git *), Bash(cat *), Bash(echo *), Bash(tail *), Bash(grep *), Bash(open *), Bash(defaults read *), Read, Write, Monitor
---

Run the **full TestFlight loop** for HomeClaw via `scripts/release.sh` (asc): bump and tag the build, generate notes, archive, upload to App Store Connect, submit to the External Testers group, and confirm processing. The pipeline is long (8–20 min) so it MUST be run via Monitor so progress events stream into the conversation as they happen.

## Pre-flight

1. Verify the working tree is clean and on `main`:
   ```bash
   git status
   git rev-parse --abbrev-ref HEAD
   ```
   Abort if dirty or on a feature branch — release builds should ship from `main`.

2. Check what's shipping. Generate release notes from commits since the last release tag (release tags are `v{version}+{build}`; `release.sh` strips the `+build` suffix when reading the version):
   ```bash
   LAST_TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null)
   git log --oneline "$LAST_TAG..HEAD"
   ```

3. Draft tester notes to a file (NOT inline — multiline + bullet points read better, and the file persists if you need to retry the submit step). Keep it user-facing: what features they get, what bugs were fixed. Avoid commit-hash speak.
   ```bash
   # Write notes to /tmp/homeclaw_testflight_notes.txt
   ```

4. Commit and tag the build number **before** building (the uploaded binary must match a pushed, tagged commit; `beta` refuses otherwise):
   ```bash
   scripts/release.sh bump-build
   git commit -m "chore(release): build NNN" Resources/Info.plist
   git tag -a v1.0.0+NNN -m "Release v1.0.0 build NNN" -m "<short summary>"
   git push && git push origin v1.0.0+NNN
   ```

## Run the pipeline (with Monitor)

`beta` does: guards → prepare (xcodegen + npm ci + MCP build) → archive → export .pkg → validate → upload to Internal Testers and wait for processing. `external` then adds the build to External Testers, sets What to Test, notifies, and submits for beta review. Both exit non-zero on any failure. Use `run_in_background` so the Monitor can stream from its log file while you keep working.

```bash
export TF_CHANGELOG="$(cat /tmp/homeclaw_testflight_notes.txt)"
{ scripts/release.sh beta && scripts/release.sh external; } 2>&1 | tee /tmp/homeclaw_archive.log
```

Run with `run_in_background: true`. **Then arm a Monitor** to surface milestones:

```bash
tail -f /tmp/homeclaw_archive.log | grep -E --line-buffered "==>|Error|error|fail|FAIL|Uploaded|Distribute|Build [0-9]+|TestFlight|warning|Traceback|Dry run"
```

The grep alternation MUST cover failure signatures (`Error|fail|Traceback`) — silence is not success.

| Time | Event |
|---|---|
| 0s | Preflight + xcodegen + MCP build |
| ~2 min | `==> Archive HomeClaw 1.0.x (NNN)` + bundle checks |
| ~3–5 min | Export + validate, then `==> Upload to TestFlight` |
| ~6–15 min | Processing wait → `Uploaded ...`, then `==> Distribute ... to External Testers` |

## After the pipeline

When the background task completes (exit 0), read the tail of the log to capture the build number, then:

1. **Verify final status**:
   ```bash
   scripts/release.sh status --build NNN
   ```
   Expected: processing `VALID`; external review may still be waiting (usually clears within an hour).

2. **Final report**: version, build number, External status, tag URL, App Store Connect URL (`https://appstoreconnect.apple.com/apps/6759682551/testflight`).

3. Per global memory, generate a TestFlight tester update message (see `memory/testflight-updates.md`) and offer to send it.

## If a step fails

| Failure | Recovery |
|---|---|
| Prepare/Archive fails | Read `.asc/logs/<step>.log`, fix the build issue, re-run `scripts/release.sh beta`. The committed build number doesn't change on failure. |
| Upload fails | Check `scripts/release.sh status --build NNN` first. If the build never arrived, re-run `beta`; if it did, don't. |
| External distribution fails but upload succeeded | Re-run only that step: `TF_CHANGELOG="$(cat /tmp/homeclaw_testflight_notes.txt)" scripts/release.sh external --build NNN`. |
| `MARKETING_VERSION` rejected as invalid | The git tag has a `+build` suffix that wasn't stripped. Check `marketing_version` in `scripts/release.sh`. |

## Common gotchas
- **Don't tail the log via Bash and wait** — that blocks the conversation. Always use Monitor with a filtering grep so events arrive incrementally.
- **Sourcing secrets is not required** — `release.sh` uses the shell's `ASC_*` exports, else loads `~/.secrets-macbook-pro.env` then `.env.local`.
- **Tester notes preview** — App Store Connect truncates after ~4000 chars; keep the doc lean.
- **Never re-trigger the upload after failure-then-success** — duplicate Build NNN uploads will be rejected by Apple. Always check `scripts/release.sh status` first.
