#!/usr/bin/env python3
"""Source-wiring regression for the two compile-time Integrations variants.

Behavior of the bound controller is exercised by HTTPIntegrationLifecycleTests.
This guard catches a setting accidentally omitted from the APP_STORE branch.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class IntegrationSettingsWiringTests(unittest.TestCase):
    def test_development_and_app_store_include_shared_http_control(self):
        development = (ROOT / 'Sources/homeclaw/Views/IntegrationsSettingsView.swift').read_text()
        settings = (ROOT / 'Sources/homeclaw/Views/SettingsView.swift').read_text()
        app_store = settings.split('private struct AppStoreIntegrationsView: View {', 1)[1]
        self.assertTrue('NativeHTTPSettingsSection()' in development, 'Development Integrations must include the shared HTTP toggle')
        self.assertTrue('NativeHTTPSettingsSection()' in app_store, 'App Store Integrations must include the shared HTTP toggle')
        self.assertIn('struct NativeHTTPSettingsSection: View', development)
        self.assertIn('httpIntegration.setEnabled($0)', development)


if __name__ == '__main__':
    unittest.main()
