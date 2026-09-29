# Release pipeline

Everything runs from the repo root through one script:

```bash
scripts/release.sh help
```

It drives the App Store Connect CLI, [`asc`](https://github.com/rorkai/App-Store-Connect-CLI)
(`brew install asc`), plus `xcodegen`, `npm` and plain `xcodebuild`. There is
no Ruby, bundler, or fastlane toolchain. Screenshot capture needs `xcparse`
(`brew install chargepoint/xcparse/xcparse`), framing needs ImageMagick
(`brew install imagemagick`), and staging screenshots for upload needs Pillow
for Homebrew Python (`/opt/homebrew/bin/python3 -m pip install Pillow`).

HomeClaw ships one product: the Mac Catalyst app `com.shahine.homeclaw` on the
**Mac App Store** (ASC platform `MAC_OS`). `homeclaw-cli`, `macOSBridge.bundle`,
`mcp-server.js` and the OpenClaw plugin are embedded in it. There is no iOS
listing and no Developer ID build: the HomeKit entitlement is App Store-only
on macOS.

## Credentials

Auth is App Store Connect API key only. No Apple ID password, no 2FA prompt,
no Keychain. An interactive shell already exports `ASC_KEY_ID`,
`ASC_ISSUER_ID`, and `ASC_PRIVATE_KEY_PATH` from `~/.zshrc`. When they are
missing, `release.sh` sources `~/.secrets-macbook-pro.env` (chezmoi-managed)
and then `.env.local`, and maps the canonical names:

| Variable | Purpose |
|---|---|
| `APP_STORE_CONNECT_API_KEY_ID` | Key ID |
| `APP_STORE_CONNECT_API_ISSUER_ID` | Issuer ID |
| `APP_STORE_CONNECT_API_KEY_PATH` | Absolute path to the `.p8` private key |
| `APPLE_TEAM_ID` | Developer team |

`HOMEKIT_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_PATH` in
`.env.local` are optional per-project overrides. `HOMEKIT_TEAM_ID` wins over
`APPLE_TEAM_ID`.

There is no `match` setup and no certificate repo. The archive uses Xcode
automatic signing (headless, via the API key), but the **export** is manual:
`beta` downloads the `com.shahine.homeclaw AppStore` profile (type
`MAC_CATALYST_APP_STORE`) with `asc profiles download`, checks that its
certificate is in this Mac's keychain, installs it, and exports pinned to it.
The `.pkg` needs two certificates in your login keychain: **Apple
Distribution** (the app) and **3rd Party Mac Developer Installer** (the
package). The profile expires 2027-07-30. `beta` never creates or repairs
profiles. When one goes INVALID (a capability change on the bundle ID does
that) or expires, repair it explicitly:

```bash
scripts/release.sh profiles                      # read-only report
scripts/release.sh profiles --repair --dry-run   # show the plan
scripts/release.sh profiles --repair             # recreate against the newest Apple Distribution cert
scripts/release.sh profiles --prune              # delete stale "<name> <timestamp>" copies from sigh
```

The profile names live in `PROFILES` at the top of `release.sh`.

Host gotchas the script handles:

- Xcode's export step shells out to `rsync` and needs the system one. With
  Homebrew rsync 3.4.x first on `PATH`, export dies with an opaque
  `Copy failed`; `release.sh` puts `/usr/bin` first.
- If export fails, the useful log is the `.xcdistributionlogs` bundle path
  printed by xcodebuild (`IDEDistribution.standard.log`).
- The Xcode is resolved from `.xcode-version` by version number (override
  with `DEVELOPER_DIR` or `XCODE_APP`), and `beta` refuses a beta Xcode,
  because App Review rejects those builds only at submission time.
- `beta` refuses to start while another `xcodebuild` runs against
  `HomeClaw.xcodeproj`; concurrent builds wedge the build service.

## Commands

| Command | What it does | Was |
|---|---|---|
| `info` | Version (nearest `v*` tag), build number, release tag, Xcode | — |
| `status [--build N]` | ASC versions, builds, TestFlight groups (read-only) | `fastlane status`, `auth_check` |
| `bump-build` | Write the next build number (and the tag's version) to `Resources/Info.plist` | the post-upload `chore(release)` commit |
| `archive` | xcodegen + MCP build + archive only | `fastlane archive` |
| `profiles [--repair] [--prune]` | Check, regenerate, or prune the App Store profiles | `sigh` (implicit) |
| `beta [--dry-run]` | Archive, export `.pkg`, validate, upload to **TestFlight Internal Testers** | `fastlane upload` |
| `external [--build N]` | Add a build to External Testers, notify, submit beta review | second half of `fastlane beta`, `fastlane submit_only` |
| `metadata [--dry-run]` | Push `appstore/metadata/` to the version | `fastlane upload_metadata` |
| `metadata-pull [--live]` | Overwrite `appstore/metadata/` from ASC | — |
| `release [--dry-run]` | Create/update the version, push metadata + screenshots, **submit for review** | submit half of `fastlane release`, `fastlane release_build` |
| `submit [--dry-run]` | Submit an uploaded build, skipping metadata | — |
| `screenshots` | Capture raw shots with the Catalyst UI tests | `fastlane screenshots` |
| `frame` | Gradient + window + tagline | `scripts/frame_screenshots.sh` |
| `upload-screenshots [--dry-run]` | Replace the ASC desktop screenshot set | `fastlane upload_screenshots` |

Every read-only command and every `--dry-run` runs with `ASC_READ_ONLY=1`, so
`asc` refuses any write before it is sent.

### TestFlight is not App Store submission

`beta` and `release` are deliberately separate, and nothing chains them.
`beta` gets a build into TestFlight and stops there. `external` puts it in
front of external testers. `release` submits to App Review: an explicit,
separate decision.

```bash
scripts/release.sh bump-build                    # Resources/Info.plist -> next build
git commit -m "chore(release): build 198" Resources/Info.plist
git tag -a v1.0.12+198 -m "Release v1.0.12 build 198"
git push && git push origin v1.0.12+198

scripts/release.sh beta --dry-run                # everything except the upload
scripts/release.sh beta                          # -> TestFlight Internal Testers, nothing else
TF_CHANGELOG="$(cat /tmp/notes.txt)" \
  scripts/release.sh beta                        # custom tester notes
# Without TF_CHANGELOG the tester notes are metadata/en-US/release_notes.txt.

scripts/release.sh external                      # current build -> External Testers
scripts/release.sh release --dry-run             # show what would be submitted
scripts/release.sh release                       # -> submits to App Review
scripts/release.sh release --build 198 --notes-file /tmp/whats-new.txt
scripts/release.sh release --notes-only --skip-screenshots   # leave the live listing alone
```

`release` options:

- `--notes-file F` / `--notes TEXT`: "What's New" for this submission
  (default: `metadata/en-US/release_notes.txt`, which must not be empty).
- `--notes-only`: push only "What's New"; description, keywords, subtitle and
  URLs on the live listing stay as they are. Use it when `appstore/metadata/`
  is older than the listing.
- `--skip-screenshots`: leave the live screenshot set alone. By default
  `release` replaces it with `appstore/framed/`.
- `--auto-release`: release as soon as Apple approves. The default parks the
  approved version in "Pending Developer Release" until you ship it.

### Versions and build numbers

The **marketing version** comes from the nearest `v*` git tag, with the
`+build` suffix stripped (Apple rejects the extra component). Start a new
version with `scripts/bump-version.sh 1.0.13` and tag `v1.0.13`.

The **build number** is `CFBundleVersion` in `Resources/Info.plist`, as
committed. `project.yml`'s "Increment Build Number (Archive Only)" pre-build
script writes that plist from `.build-number` + 1 and the tag during every
Release build, so `beta` seeds `.build-number` with the committed build minus
one: the script then lands on exactly the committed values. `beta` also
snapshots the plist and restores it on success and failure, then checks the
archived binary reports the committed version and build.

### Release integrity

`beta` refuses to run unless all of these hold (with `--dry-run` the tag and
push checks warn instead, so the build path can be verified first):

- The worktree is clean (a failed `git status` counts as dirty).
- HEAD carries a `vX.Y[.Z]` or `vX.Y[.Z]+BUILD` tag whose version and build
  match the nearest tag and `Resources/Info.plist`.
- `Resources/Info.plist`'s version matches the tag.
- HEAD is on a remote branch.
- `npm ci && npm run build:mcp` reproduces the committed
  `mcp-server/dist/server.js` byte for byte (build 196 shipped a stale MCP SDK).
- The HomeKit entitlement is in `Resources/HomeClaw.entitlements`, and after
  archiving it is on the signed app and `homeclaw-cli` is sandboxed (build 154
  was rejected with error 90296 for an unsandboxed CLI).

## App Store metadata

`appstore/metadata/` is the version-controlled source of truth, in the
fastlane layout that `asc migrate import --fastlane-dir appstore` reads.
`release` and `metadata` push every file in it, including
`review_information/`, copyright and categories.

```
appstore/metadata/
├── copyright.txt
├── primary_category.txt
├── secondary_category.txt
├── review_information/
└── en-US/
    ├── description.txt
    ├── keywords.txt
    ├── marketing_url.txt
    ├── name.txt
    ├── privacy_url.txt
    ├── promotional_text.txt
    ├── release_notes.txt
    ├── subtitle.txt
    └── support_url.txt
```

`metadata --dry-run` prints the diff between these files and App Store
Connect. If someone changed something in the web UI, pull it back first so
the edit lands as a reviewable diff instead of being overwritten:

```bash
scripts/release.sh metadata-pull
git diff appstore/metadata
```

`metadata-pull` **overwrites** local files with what ASC holds. It reads the
version being prepared, falling back to the live one (deliver's precedence).
`--live` reads the shipped listing on purpose.

## Screenshots

`screenshots` runs the `HomeClawUITests` scheme on this Mac
(`platform=macOS,variant=Mac Catalyst`) with plain `xcodebuild test`, then
extracts the attachments with `xcparse`. The app runs in **demo mode**
(`--ui-test-demo`): `HomeKitManager` serves `DemoFixtures` instead of real
HomeKit data. The tests drive real windows, so leave the Mac alone while they
run.

```bash
scripts/release.sh screenshots                   # appstore/screenshots/en-US (raw)
scripts/release.sh frame                         # appstore/framed/en-US (uploaded)
scripts/release.sh upload-screenshots --dry-run
```

Both folders are committed. `upload-screenshots` maps 2880×1800 (and the
other Mac sizes) to the `APP_DESKTOP` set and refuses to replace it while any
raw screenshot lacks a framed counterpart (`--allow-partial` overrides), since
a replace deletes the whole set first.

See [MANUAL_SCREENSHOTS.md](MANUAL_SCREENSHOTS.md) for the framing setup and
the shots the UI tests can't produce.
