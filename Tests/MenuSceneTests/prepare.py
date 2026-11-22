"""Extract production methods for API-shaped doubles; never load real HomeKit.

The entire AppKit implementation is compiled with only status-item creation
bypassed, so no real menu/status item or foreground window is created.
"""
import hashlib
import json
from pathlib import Path
import sys

root, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
paths = {
    "manager": "Sources/homeclaw/HomeKit/HomeKitManager.swift",
    "model": "Sources/homeclaw/HomeKit/AccessoryModel.swift",
    "bridge": "Sources/macOSBridge/MacOSController.swift",
    "protocols": "Sources/homeclaw/Bridge/BridgeProtocols.swift",
    "app": "Sources/homeclaw/App/HomeClawApp.swift",
    "policy": "Sources/homeclaw/Shared/MenuScenePolicy.swift",
}
sources = {key: (root / path).read_text() for key, path in paths.items()}


def extract(source, signature):
    start = source.index(signature)
    pos = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[pos] == "{") - (source[pos] == "}")
        pos += 1
    return source[start:pos]


# The AppKit callback reaches a UIKit host that this macOS-only fixture cannot
# instantiate. Keep that single menu-only route wired to the invocation check.
app_callback = extract(sources["app"], "func triggerScene(id: String)")
assert "HomeKitManager.shared.triggerScene(id: id, fromMenu: true)" in app_callback

bridge = sources["bridge"]
call = "        setupStatusItem()\n"
assert bridge.count(call) == 1
bridge = bridge.replace(call, "        // Offscreen fixture: do not create a status item.\n")
bridge += """
extension MacOSController {
    func fixtureMenu(_ data: [String: Any]?, ready: Bool = false) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        populateMenu(menu, data: data, ready: ready)
        menu.update()
        return menu
    }
}
"""
(out / "MacOSController.swift").write_text(bridge)
(out / "BridgeProtocols.swift").write_text(sources["protocols"])
methods = [extract(sources["manager"], signature) for signature in [
    "func buildMenuData() -> [String: Any]",
    "private func filterAccessories(_ accessories: [HMAccessory])",
    "private func isAccessoryAllowed(_ accessory: HMAccessory)",
    "private func menuSceneDisabledReason(_ actionSet: HMActionSet, in home: HMHome)",
    "private func allActionSets(in home: HMHome)",
    "func triggerScene(id: String, homeID:",
]]
model = [extract(sources["model"], signature) for signature in [
    "static func sceneSummary(_ actionSet: HMActionSet)",
    "private static func actionSetType(_ actionSet: HMActionSet)",
    "static func isoDateOrNull(_ date: Date?)",
]]
(out / "ExtractedMethods.swift").write_text(
    "import Foundation\n@MainActor final class FixtureManager {\n"
    + (root / "Tests/MenuSceneTests/ManagerMembers.swift.txt").read_text()
    + "\n".join(methods) + "\n}\n@MainActor enum AccessoryModel {\n"
    + """static func accessorySummary(_ accessory: HMAccessory, cachedState: [String: String], bridge: [String: Any]?, bridgedAccessoryIDs: [String]) -> [String: Any] {
        ["id": accessory.uniqueIdentifier.uuidString, "name": accessory.name, "category": accessory.category, "reachable": true, "state": cachedState]
    }
""" + "\n".join(model) + "\n}\n")
(out / "source-hashes.json").write_text(json.dumps({
    "sources": {paths[k]: hashlib.sha256(v.encode()).hexdigest() for k, v in sources.items()},
    "extracted_methods": [hashlib.sha256(v.encode()).hexdigest() for v in methods + model],
}, indent=2) + "\n")
