#!/bin/bash
# HomeKit-free production discovery fixture: no app, socket, reads or writes.
set -euo pipefail
cd "$(dirname "$0")/.."
evidence="${SERVICE_DISCOVERY_EVIDENCE_DIR:-$PWD/.build/service-discovery}"
mkdir -p "$evidence"
evidence="$(cd "$evidence" && pwd)"
python3 Tests/ServiceDiscoveryIntegration/prepare.py "$PWD" "$evidence"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -module-cache-path "$evidence/ModuleCache" \
  "$evidence/Constants.swift" "$evidence/CharacteristicMapper.swift" "$evidence/DeviceMap.swift" \
  "$evidence/Extracted.swift" Sources/homeclaw/Shared/ServiceDiscovery.swift \
  Tests/ServiceDiscoveryIntegration/Stubs.swift Tests/ServiceDiscoveryIntegration/Runner.swift \
  -o "$evidence/ServiceDiscoveryTests"
"$evidence/ServiceDiscoveryTests" "$evidence" | tee "$evidence/results.txt"
