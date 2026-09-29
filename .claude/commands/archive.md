---
description: Create xcarchive for TestFlight
allowed-tools: Bash(scripts/release.sh *), Bash(open *)
---

Create an Xcode archive for TestFlight / App Store distribution.

1. Run `scripts/release.sh archive`
2. Report the archive location and version
3. Ask if the user wants to open in Xcode Organizer: `open .asc/artifacts/HomeClaw.xcarchive`
