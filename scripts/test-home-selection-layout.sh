#!/bin/bash
# Offscreen SwiftUI layout/interaction regression; no HomeKit, installed app, or UI automation.
set -euo pipefail
cd "$(dirname "$0")/.."
evidence="${HOME_SELECTION_EVIDENCE_DIR:-$PWD/.build/home-selection-layout}"
mkdir -p "$evidence"
evidence="$(cd "$evidence" && pwd)"
xcrun swiftc -swift-version 6 -strict-concurrency=complete \
  -module-cache-path "$evidence/ModuleCache" -parse-as-library \
  Sources/homeclaw/Views/HomeSelectionView.swift \
  Tests/HomeSelectionLayoutTests/HomeSelectionLayoutTests.swift \
  -o "$evidence/HomeSelectionLayoutTests"
"$evidence/HomeSelectionLayoutTests" "$evidence" | tee "$evidence/results.txt"
