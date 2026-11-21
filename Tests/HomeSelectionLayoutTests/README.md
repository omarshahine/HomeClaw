The offscreen regression hosts the production `HomeSelectionView` in AppKit with
synthetic homes. Run `bash scripts/test-home-selection-layout.sh`. It checks
normal, narrow, short and combined narrow/short layouts, scrolling, selection,
and Continue before/after scrolling, without foreground UI or HomeKit.

For the actual Catalyst onboarding flow, generate the project, install npm
workspaces, then run `bash scripts/test-onboarding-ui.sh`. Select an existing
Xcode with `DEVELOPER_DIR` and, if needed, an existing development identity with
`HOMECLAW_UI_SIGNING_IDENTITY`. The script builds a distinct Debug app identity,
uses UUID-scoped temporary configuration, disables live services/integration
setup, and never enables Automation Mode or changes signing/security settings.
The tests cover routing, 1/2/7/20 homes, the fixed footer, scrolling, selection,
full normal-size navigation, persistence, a removed default home, and Skip while
HomeKit is unavailable. App Store screenshot tests remain separate.

A successful offscreen run does not prove Catalyst navigation/accessibility or
live HomeKit behavior. A runner launch failure is a coverage gap, not a passing
UI test; inspect its xcresult and report it.
