#!/bin/bash
# Actual offscreen AppKit menus + exact snapshot/execution methods with synthetic HomeKit doubles.
set -euo pipefail
cd "$(dirname "$0")/.."
evidence="${MENU_SCENE_EVIDENCE_DIR:-$PWD/.build/menu-scenes}"
mkdir -p "$evidence"
evidence="$(cd "$evidence" && pwd)"
python3 Tests/MenuSceneTests/prepare.py "$PWD" "$evidence"
xcrun swiftc -swift-version 6 -strict-concurrency=complete \
  -module-cache-path "$evidence/ModuleCache" -parse-as-library \
  Sources/homeclaw/Shared/MenuScenePolicy.swift Sources/macOSBridge/LocalGitHubStar.swift \
  Tests/MenuSceneTests/Stubs.swift Tests/MenuSceneTests/Runner.swift \
  "$evidence/BridgeProtocols.swift" "$evidence/MacOSController.swift" "$evidence/ExtractedMethods.swift" \
  -o "$evidence/MenuSceneTests"
"$evidence/MenuSceneTests" "$evidence" | tee "$evidence/results.txt"
