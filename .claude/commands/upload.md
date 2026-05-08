---
description: Archive, upload, and submit to external TestFlight (full loop with monitor)
allowed-tools: Bash(fastlane *), Bash(git *), Bash(cat *), Bash(echo *), Bash(tail *), Bash(grep *), Bash(open *), Bash(defaults read *), Read, Write, Monitor
---

Run the **full TestFlight loop** for HomeClaw via fastlane: generate notes, archive, upload to App Store Connect, submit to the External Testers group, tag the release, and confirm processing. The pipeline is long (8–20 min) so it MUST be run via Monitor so progress events stream into the conversation as they happen.

## Pre-flight

1. Verify the working tree is clean and on `main`:
   ```bash
   git status
   git rev-parse --abbrev-ref HEAD
   ```
   Abort if dirty or on a feature branch — release builds should ship from `main`.

2. Check what's shipping. Generate release notes from commits since the last release tag (release tags are `v{version}+{build}`; the Fastfile auto-strips the `+build` suffix when re-archiving so a stale tag won't break it):
   ```bash
   LAST_TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null)
   git log --oneline "$LAST_TAG..HEAD"
   ```

3. Draft tester notes to a file (NOT inline — multiline + bullet points read better, and the file persists if you need to retry the submit step). Keep it user-facing: what features they get, what bugs were fixed. Avoid commit-hash speak.
   ```bash
   # Write notes to /tmp/homeclaw_testflight_notes.txt
   ```

## Run the pipeline (with Monitor)

The `beta` lane does: prepare (xcodegen + MCP build) → archive → export → upload → submit external. It exits non-zero on any failure. Use `run_in_background` so the Monitor can stream from its log file while you keep working.

```bash
fastlane beta notes_file:/tmp/homeclaw_testflight_notes.txt 2>&1 | tee /tmp/homeclaw_archive.log
```

Run with `run_in_background: true`. **Then arm a Monitor** to surface milestones:

```bash
tail -f /tmp/homeclaw_archive.log | grep -E --line-buffered "✓|finished successfully|Error|error|fail|FAIL|Submitting|Uploading|Build [0-9]+|TestFlight|version|warning|Traceback|EXPORT SUCCEEDED|Upload succeeded|external group"
```

The grep alternation MUST cover failure signatures (`Error|fail|Traceback`) — silence is not success.

| Time | Event |
|---|---|
| 0s | xcodegen + MCP build |
| ~2 min | Archive succeeds, version banner `v1.0.x build NNN` + bundle checks |
| ~3–5 min | `Uploading to App Store Connect…` then upload succeeds |
| ~6–15 min | TestFlight processing wait → `submitted to external group 'NAME'` |

## After the pipeline

When the background task completes (exit 0), read the tail of the log to capture the build number, then:

1. **Verify final status**:
   ```bash
   fastlane status
   ```
   Expected: `Processing: VALID`, `External: IN_BETA_TESTING` (or `WAITING_FOR_BETA_REVIEW` if Apple hasn't approved yet — usually clears within an hour).

2. **Commit the bumped Info.plist**:
   ```bash
   git add Resources/Info.plist
   git commit -m "chore(release): build NNN"
   git push
   ```

3. **Tag the release** as `v{version}+{build}`:
   ```bash
   git tag -a v1.0.0+NNN -m "Release v1.0.0 build NNN" -m "<short summary>"
   git push origin v1.0.0+NNN
   ```

4. **Final report**: version, build number, External status, tag URL, App Store Connect URL (`https://appstoreconnect.apple.com/apps/6759682551/testflight`).

5. Per global memory, generate a TestFlight tester update message (see `memory/testflight-updates.md`) and offer to send it.

## If a step fails

| Failure | Recovery |
|---|---|
| Prepare/Archive fails | Read the log, fix the build issue, re-run `fastlane beta`. Build number does NOT increment on failure (`.build-number` is only read, not written). |
| Upload fails | The .xcarchive at `.build/archives/HomeClaw.xcarchive` and .ipa at `.build/export/HomeClaw.ipa` are reusable. Re-run `fastlane beta` (it'll re-archive) or use `fastlane submit_only build:NNN` if the upload itself succeeded but submit didn't. |
| Submit fails but Upload succeeded | Re-run only the submit standalone: `fastlane submit_only build:NNN notes_file:/tmp/homeclaw_testflight_notes.txt`. |
| `MARKETING_VERSION` rejected as invalid | The git tag has a `+build` suffix that wasn't stripped. Confirm `fastlane/Fastfile`'s `marketing_version` helper does `tag.delete_prefix("v").split("+").first`. |

## Common gotchas
- **Don't tail the log via Bash and wait** — that blocks the conversation. Always use Monitor with a filtering grep so events arrive incrementally.
- **`source ~/.secrets.env` is not required** — the Fastfile's `load_env_file` helper loads `.env.local` first, then `~/.secrets.env`.
- **Tester notes preview** — App Store Connect truncates after ~4000 chars; keep the doc lean.
- **Never re-trigger the upload after failure-then-success** — duplicate Build NNN uploads will be rejected by Apple. Always check `fastlane status` first.
