#!/usr/bin/env python3
"""Verify generated UI schemes cannot mix the real and synthetic app identities."""
import json
import plistlib
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[1]
for scheme, config, selected, identity, entitlements in [
    ("HomeClawUITests", "Debug", "ScreenshotTests", "com.shahine.homeclaw", "Resources/HomeClaw.entitlements"),
    ("HomeClawOnboardingTests", "DebugUI", "OnboardingRegressionTests", "com.shahine.homeclaw.ui-regression", "Resources/UIRegression.entitlements"),
    ("HomeClaw", "Release", None, "com.shahine.homeclaw", "Resources/HomeClaw.entitlements"),
]:
    if selected:
        xml = ET.parse(root / "HomeClaw.xcodeproj/xcshareddata/xcschemes" / (scheme + ".xcscheme"))
        action = xml.getroot().find("TestAction")
        assert action.get("buildConfiguration") == config, (scheme, "wrong test configuration")
        testables = action.findall("./Testables/TestableReference")
        assert len(testables) == 1 and testables[0].get("useTestSelectionWhitelist") == "YES", (scheme, "selection whitelist disabled")
        assert testables[0].find("BuildableReference").get("BlueprintName") == "HomeClawUITests"
        assert [t.get("Identifier") for t in action.findall(".//SelectedTests/Test")] == [selected], (scheme, "mixed test classes")
    result = subprocess.run([
        "xcodebuild", "-project", "HomeClaw.xcodeproj", "-scheme", scheme,
        "-configuration", config, "-destination", "platform=macOS,variant=Mac Catalyst",
        "-showBuildSettings", "-json",
    ], cwd=root, capture_output=True, text=True, check=True)
    settings = next(row["buildSettings"] for row in json.loads(result.stdout) if row["target"] == "HomeClaw")
    assert settings["PRODUCT_BUNDLE_IDENTIFIER"] == identity, (scheme, "wrong app identity")
    assert settings["CODE_SIGN_ENTITLEMENTS"] == entitlements, (scheme, "wrong entitlements")
    contents = plistlib.loads((root / entitlements).read_bytes())
    if config == "DebugUI":
        assert contents == {}, "Synthetic UI app must have no production capabilities"
        assert "DEBUG" in settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"].split()
    else:
        assert contents.get("com.apple.developer.homekit") is True
        assert "group.com.shahine.homeclaw" in contents.get("com.apple.security.application-groups", [])
    print(f"PASS {scheme}: {config}, {identity}, {entitlements}")
