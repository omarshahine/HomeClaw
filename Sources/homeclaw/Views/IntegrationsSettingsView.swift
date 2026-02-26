import SwiftUI
import UIKit

struct IntegrationsSettingsView: View {
    @State private var claudeDesktopStatus: DesktopStatus = .checking
    @State private var claudeCodeStatus: ClaudeCodeStatus = .checking
    @State private var openClawStatus: OpenClawStatus = .checking
    @State private var cliStatus: CLIStatus = .checking
    @State private var statusMessage: StatusMessage?

    // MARK: - Status Enums

    private enum DesktopStatus {
        case checking
        case notInstalled
        case installed
        case nodeNotFound
    }

    private enum ClaudeCodeStatus {
        /// Still checking config files.
        case checking
        /// Plugin detected in ~/.claude/settings.json enabledPlugins.
        case pluginInstalled
        /// Neither plugin nor MCP config found.
        case notInstalled
    }

    private enum CLIStatus {
        case checking
        /// Symlink exists and points to bundled binary.
        case installed
        /// Symlink missing or points elsewhere.
        case notInstalled
    }

    private enum OpenClawStatus {
        case checking
        /// ~/.openclaw/ directory doesn't exist.
        case openClawNotDetected
        /// OpenClaw present but plugin not installed.
        case notInstalled
        /// Plugin found in extensions directory or OpenClaw config.
        case installed
    }

    // MARK: - Constants & Paths

    private static let serverName = "homeclaw"
    /// Legacy server name from when the app was called "HomeKit Bridge".
    private static let legacyServerName = "homekit-bridge"
    private static let pluginPrefix = "homeclaw@"
    private static let legacyPluginPrefix = "homekit-bridge@"
    private static let githubRepo = "omarshahine/HomeClaw"
    private static let openClawPluginID = "homeclaw"
    /// Homebrew bin directory — `/opt/homebrew/bin` on Apple Silicon, `/usr/local/bin` on Intel.
    private static var homebrewBinDir: String {
        #if arch(arm64)
        return "/opt/homebrew/bin"
        #else
        return "/usr/local/bin"
        #endif
    }

    private static var cliSymlinkPath: String {
        homebrewBinDir + "/homeclaw-cli"
    }

    private static var bundledCLIPath: String {
        Bundle.main.bundlePath + "/Contents/MacOS/homeclaw-cli"
    }

    private static var claudeDesktopConfigPath: String {
        AppConfig.realHomeDirectory
            + "/Library/Application Support/Claude/claude_desktop_config.json"
    }

    private static var claudeCodeSettingsPath: String {
        AppConfig.realHomeDirectory + "/.claude/settings.json"
    }

    private static var openClawConfigPath: String {
        AppConfig.realHomeDirectory + "/.openclaw/openclaw.json"
    }

    /// Path to the bundled mcp-server.js inside the app's Resources.
    private static var bundledServerJSPath: String? {
        let path = Bundle.main.bundlePath + "/Contents/Resources/mcp-server.js"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Path to the bundled OpenClaw plugin directory inside the app's Resources.
    private static var bundledOpenClawPluginPath: String? {
        let path = Bundle.main.bundlePath + "/Contents/Resources/openclaw"
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            ? path : nil
    }

    /// Path to the installed OpenClaw plugin in the extensions directory.
    private static var openClawExtensionsPath: String {
        AppConfig.realHomeDirectory
            + "/.openclaw/extensions/homeclaw"
    }

    // MARK: - Body

    var body: some View {
        Form {
            cliSection
            claudeDesktopSection
            claudeCodeSection
            openClawSection

            if let message = statusMessage {
                Section {
                    Label(
                        message.text,
                        systemImage: message.isError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .foregroundStyle(message.isError ? .red : .green)
                }
            }

            Section {
                Text(
                    "After installing or updating, restart the target application to load the new MCP configuration."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, -8)
        .onAppear {
            refreshStatuses()
        }
    }

    // MARK: - CLI Section

    @ViewBuilder
    private var cliSection: some View {
        Section {
            LabeledContent("Status") {
                cliStatusLabel
            }

            if cliStatus == .installed {
                LabeledContent("Path") {
                    Text(Self.cliSymlinkPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            HStack {
                Button(cliStatus == .installed ? "Reinstall" : "Install") {
                    installCLISymlink()
                }

                if cliStatus == .installed {
                    Button("Remove", role: .destructive) {
                        removeCLISymlink()
                    }
                }
            }

            Text("Creates a symlink at \(Self.cliSymlinkPath) pointing to the bundled binary. Requires administrator privileges.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Command Line").font(.headline).foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private var cliStatusLabel: some View {
        switch cliStatus {
        case .checking:
            Label("Checking\u{2026}", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notInstalled:
            Label("Not Installed", systemImage: "circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Claude Desktop Section

    @ViewBuilder
    private var claudeDesktopSection: some View {
        Section {
            LabeledContent("Status") {
                desktopStatusLabel
            }

            if let path = Self.bundledServerJSPath {
                LabeledContent("MCP Server") {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            HStack {
                Button(claudeDesktopStatus == .installed ? "Reinstall" : "Install") {
                    installClaudeDesktop()
                }
                .disabled(claudeDesktopStatus == .nodeNotFound)

                if claudeDesktopStatus == .installed {
                    Button("Remove", role: .destructive) {
                        remove(from: Self.claudeDesktopConfigPath)
                        claudeDesktopStatus = .notInstalled
                    }
                }
            }

            if claudeDesktopStatus == .nodeNotFound {
                Text("Node.js is required for Claude Desktop integration. Install from nodejs.org.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if Self.bundledServerJSPath == nil {
                Text("MCP server not bundled. Rebuild with: npm run build:mcp && scripts/build.sh")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Uses the bundled stdio MCP server. Requires Node.js.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Claude Desktop").font(.headline).foregroundStyle(.primary)
        }
    }

    // MARK: - Claude Code Section

    @ViewBuilder
    private var claudeCodeSection: some View {
        Section {
            LabeledContent("Status") {
                claudeCodeStatusLabel
            }

            switch claudeCodeStatus {
            case .pluginInstalled:
                Text("HomeClaw plugin is installed and active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .notInstalled:
                Button("Copy Install Commands") {
                    copyInstallCommands()
                }

                installInstructionsView

            case .checking:
                EmptyView()
            }
        } header: {
            Text("Claude Code").font(.headline).foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private var installInstructionsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Run these commands in Claude Code:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("/plugin marketplace add \(Self.githubRepo)")
                Text("/plugin install homeclaw@homeclaw")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }

    // MARK: - OpenClaw Section

    @ViewBuilder
    private var openClawSection: some View {
        Section {
            LabeledContent("Status") {
                openClawStatusLabel
            }

            switch openClawStatus {
            case .installed:
                Text("HomeClaw plugin is installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Remove", role: .destructive) {
                    removeOpenClawPlugin()
                }

            case .notInstalled:
                if openClawCLIPath() != nil {
                    HStack {
                        Button("Install") {
                            installOpenClawPlugin()
                        }
                        .disabled(Self.bundledOpenClawPluginPath == nil)

                        Button("Copy Setup Instructions") {
                            copyOpenClawSetupInstructions()
                        }
                    }

                    if Self.bundledOpenClawPluginPath == nil {
                        Text("Plugin not bundled. Rebuild with: scripts/build.sh")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Installs the plugin, symlinks homeclaw-cli into PATH, and restarts the gateway.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Copy Setup Instructions") {
                        copyOpenClawSetupInstructions()
                    }

                    openClawRemoteInstructionsView
                }

            case .openClawNotDetected:
                Button("Copy Setup Instructions") {
                    copyOpenClawSetupInstructions()
                }

                Text("OpenClaw not detected locally. Use the setup instructions for a remote gateway.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .checking:
                EmptyView()
            }
        } header: {
            Text("OpenClaw").font(.headline).foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private var openClawRemoteInstructionsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OpenClaw CLI not found locally. For a remote gateway:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("openclaw plugins install <path-to-openclaw-dir>")
                Text("openclaw plugins enable homeclaw")
                Text("ln -sf /path/to/homeclaw-cli /opt/homebrew/bin/homeclaw-cli")
                Text("openclaw gateway restart")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }

    // MARK: - Status Labels

    @ViewBuilder
    private var desktopStatusLabel: some View {
        switch claudeDesktopStatus {
        case .checking:
            Label("Checking\u{2026}", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .notInstalled:
            Label("Not Installed", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .nodeNotFound:
            Label("Node.js Not Found", systemImage: "xmark.circle")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var claudeCodeStatusLabel: some View {
        switch claudeCodeStatus {
        case .checking:
            Label("Checking\u{2026}", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .pluginInstalled:
            Label("Plugin Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notInstalled:
            Label("Not Installed", systemImage: "circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var openClawStatusLabel: some View {
        switch openClawStatus {
        case .checking:
            Label("Checking\u{2026}", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notInstalled:
            Label("Not Installed", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .openClawNotDetected:
            Label("OpenClaw Not Detected", systemImage: "circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Status Checking

    private func refreshStatuses() {
        cliStatus = checkCLIStatus()
        claudeDesktopStatus = checkClaudeDesktopStatus()
        claudeCodeStatus = checkClaudeCodeStatus()
        openClawStatus = checkOpenClawStatus()
    }

    private func checkClaudeDesktopStatus() -> DesktopStatus {
        guard nodeJSPath() != nil else { return .nodeNotFound }

        guard let config = readConfig(at: Self.claudeDesktopConfigPath),
            let servers = config["mcpServers"] as? [String: Any],
            servers[Self.serverName] != nil || servers[Self.legacyServerName] != nil
        else {
            return .notInstalled
        }
        return .installed
    }

    private func checkClaudeCodeStatus() -> ClaudeCodeStatus {
        if isPluginEnabled() { return .pluginInstalled }
        return .notInstalled
    }

    /// Checks ~/.claude/settings.json enabledPlugins for any key matching "homeclaw@*".
    private func isPluginEnabled() -> Bool {
        guard let config = readConfig(at: Self.claudeCodeSettingsPath),
            let enabled = config["enabledPlugins"] as? [String: Any]
        else { return false }
        return enabled.keys.contains { $0.hasPrefix(Self.pluginPrefix) || $0.hasPrefix(Self.legacyPluginPrefix) }
    }

    private func checkOpenClawStatus() -> OpenClawStatus {
        let configDir = (Self.openClawConfigPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: configDir) else {
            return .openClawNotDetected
        }

        // Check extensions directory (installed via `openclaw plugins install`)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: Self.openClawExtensionsPath, isDirectory: &isDir),
            isDir.boolValue
        {
            return .installed
        }

        // Check openclaw.json config (legacy manual setup)
        if let config = readConfig(at: Self.openClawConfigPath),
            let plugins = config["plugins"] as? [String: Any]
        {
            // Check allow list
            if let allow = plugins["allow"] as? [String],
                allow.contains(Self.openClawPluginID)
            {
                return .installed
            }

            // Check entries
            if let entries = plugins["entries"] as? [String: Any],
                entries[Self.openClawPluginID] != nil
            {
                return .installed
            }

            // Check load paths for HomeClaw/openclaw
            if let load = plugins["load"] as? [String: Any],
                let paths = load["paths"] as? [String],
                paths.contains(where: { $0.contains("HomeClaw") })
            {
                return .installed
            }
        }

        return .notInstalled
    }

    private func checkCLIStatus() -> CLIStatus {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.cliSymlinkPath) else { return .notInstalled }

        // Verify it's a symlink pointing to our bundled binary
        if let dest = try? fm.destinationOfSymbolicLink(atPath: Self.cliSymlinkPath),
            dest == Self.bundledCLIPath
        {
            return .installed
        }

        // Symlink exists but points elsewhere — treat as not installed (ours)
        return .notInstalled
    }

    // MARK: - Install Actions

    private func installCLISymlink() {
        let script = """
            do shell script "ln -sf '\(Self.bundledCLIPath)' '\(Self.cliSymlinkPath)'" \
            with administrator privileges
            """
        if runAppleScript(script) {
            cliStatus = .installed
            showStatus("CLI installed at \(Self.cliSymlinkPath)", isError: false)
            AppLogger.app.info("Installed CLI symlink to \(Self.cliSymlinkPath)")
        } else {
            showStatus("CLI install cancelled or failed", isError: true)
        }
    }

    private func removeCLISymlink() {
        let script = """
            do shell script "rm '\(Self.cliSymlinkPath)'" \
            with administrator privileges
            """
        if runAppleScript(script) {
            cliStatus = .notInstalled
            showStatus("CLI symlink removed", isError: false)
            AppLogger.app.info("Removed CLI symlink")
        } else {
            showStatus("CLI removal cancelled or failed", isError: true)
        }
    }

    private func installClaudeDesktop() {
        guard let serverJS = Self.bundledServerJSPath else {
            showStatus("MCP server not bundled in app — rebuild first", isError: true)
            return
        }

        guard let nodePath = nodeJSPath() else {
            showStatus("Node.js not found — install from nodejs.org", isError: true)
            return
        }

        let entry: [String: Any] = [
            "command": nodePath,
            "args": [serverJS],
        ]

        do {
            try upsertMCPServer(entry: entry, in: Self.claudeDesktopConfigPath)
            claudeDesktopStatus = .installed
            showStatus("Claude Desktop integration installed", isError: false)
            AppLogger.app.info("Installed MCP config for Claude Desktop")
        } catch {
            showStatus("Failed: \(error.localizedDescription)", isError: true)
            AppLogger.app.error(
                "Failed to install Claude Desktop config: \(error.localizedDescription)")
        }
    }

    private func copyInstallCommands() {
        let commands = """
            /plugin marketplace add \(Self.githubRepo)
            /plugin install homeclaw@homeclaw
            """
        UIPasteboard.general.string = commands
        showStatus("Install commands copied to clipboard", isError: false)
    }

    private func copyOpenClawSetupInstructions() {
        let bundledPath = Self.bundledOpenClawPluginPath
            ?? "/Applications/HomeClaw.app/Contents/Resources/openclaw"
        let instructions = """
            # Install from the bundled plugin (if OpenClaw runs on the same Mac):
            openclaw plugins install "\(bundledPath)"
            openclaw plugins enable homeclaw

            # Symlink the CLI into PATH (the skill calls homeclaw-cli by name):
            ln -sf '/Applications/HomeClaw.app/Contents/MacOS/homeclaw-cli' '\(Self.cliSymlinkPath)'

            # Restart the gateway to load the plugin:
            openclaw gateway restart

            # Or for a remote gateway, clone the repo:
            git clone https://github.com/\(Self.githubRepo).git ~/GitHub/HomeClaw
            openclaw plugins install ~/GitHub/HomeClaw/openclaw
            openclaw plugins enable homeclaw
            ln -sf /path/to/homeclaw-cli /opt/homebrew/bin/homeclaw-cli
            openclaw gateway restart
            """
        UIPasteboard.general.string = instructions
        showStatus("Setup instructions copied to clipboard", isError: false)
    }

    private func installOpenClawPlugin() {
        guard let pluginPath = Self.bundledOpenClawPluginPath else {
            showStatus("Plugin not bundled in app — rebuild first", isError: true)
            return
        }

        guard let cliPath = openClawCLIPath() else {
            showStatus("OpenClaw CLI not found", isError: true)
            return
        }

        // Step 1: openclaw plugins install <bundledPlugin>
        let installResult = runProcess(cliPath, arguments: ["plugins", "install", pluginPath])
        guard installResult.success else {
            showStatus("Install failed: \(installResult.output)", isError: true)
            return
        }

        // Step 2: openclaw plugins enable homeclaw
        let enableResult = runProcess(cliPath, arguments: ["plugins", "enable", Self.openClawPluginID])
        guard enableResult.success else {
            showStatus("Enable failed: \(enableResult.output)", isError: true)
            return
        }

        // Step 3: Symlink homeclaw-cli into PATH so the skill can find it.
        // The skill references `homeclaw-cli` by name, so it must be in PATH.
        let symlinkScript = """
            do shell script "ln -sf '\(Self.bundledCLIPath)' '\(Self.cliSymlinkPath)'" \
            with administrator privileges
            """
        if runAppleScript(symlinkScript) {
            cliStatus = .installed
            AppLogger.app.info("Installed CLI symlink at \(Self.cliSymlinkPath) for OpenClaw")
        } else {
            AppLogger.app.warning("CLI symlink skipped — user cancelled admin prompt")
        }

        // Step 4: Restart gateway so the plugin loads
        let restartResult = runProcess(cliPath, arguments: ["gateway", "restart"])
        if !restartResult.success {
            AppLogger.app.warning("Gateway restart failed: \(restartResult.output)")
        }

        openClawStatus = .installed
        showStatus("HomeClaw plugin installed in OpenClaw", isError: false)
        AppLogger.app.info("Installed OpenClaw plugin from bundled path")
    }

    private func removeOpenClawPlugin() {
        guard let cliPath = openClawCLIPath() else {
            showStatus("OpenClaw CLI not found — remove manually", isError: true)
            return
        }

        let result = runProcess(cliPath, arguments: ["plugins", "disable", Self.openClawPluginID])
        if result.success {
            openClawStatus = .notInstalled
            showStatus("HomeClaw plugin removed from OpenClaw", isError: false)
            AppLogger.app.info("Removed OpenClaw plugin")
        } else {
            showStatus("Remove failed: \(result.output)", isError: true)
        }
    }

    // MARK: - Remove

    private func remove(from configPath: String) {
        guard var config = readConfig(at: configPath) else { return }
        guard var servers = config["mcpServers"] as? [String: Any] else { return }

        servers.removeValue(forKey: Self.serverName)
        servers.removeValue(forKey: Self.legacyServerName)
        config["mcpServers"] = servers

        do {
            try writeConfig(config, to: configPath)
            showStatus("Integration removed", isError: false)
        } catch {
            showStatus("Failed: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Config File I/O

    private func readConfig(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func writeConfig(_ config: [String: Any], to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func upsertMCPServer(entry: [String: Any], in configPath: String) throws {
        var config = readConfig(at: configPath) ?? [:]
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        // Remove legacy entry if present
        servers.removeValue(forKey: Self.legacyServerName)
        servers[Self.serverName] = entry
        config["mcpServers"] = servers
        try writeConfig(config, to: configPath)
    }

    // MARK: - Helpers

    /// Finds the absolute path to the `node` binary, or nil if not installed.
    private func nodeJSPath() -> String? {
        let knownPaths = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node",
        ]
        return knownPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Finds the absolute path to the `openclaw` binary, or nil if not installed.
    private func openClawCLIPath() -> String? {
        let knownPaths = [
            "/usr/local/bin/openclaw",
            "/opt/homebrew/bin/openclaw",
        ]
        return knownPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Runs an AppleScript string via osascript. Returns true on success.
    /// Used for privileged operations that show the macOS admin password prompt.
    /// Uses osascript because NSAppleScript is unavailable on Mac Catalyst.
    @discardableResult
    private func runAppleScript(_ source: String) -> Bool {
        let result = runProcess("/usr/bin/osascript", arguments: ["-e", source])
        return result.success
    }

    /// Runs a process synchronously via posix_spawn and returns the combined output.
    /// Uses posix_spawn because Process (NSTask) is unavailable on Mac Catalyst.
    /// Extends PATH with Homebrew bin directories so that scripts using
    /// `#!/usr/bin/env node` (like the openclaw CLI) can find Node.js.
    private func runProcess(_ path: String, arguments: [String]) -> (success: Bool, output: String) {
        // Build environment with extended PATH
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")

        // Convert args and env to C string arrays
        let cArgs = ([path] + arguments).map { $0.withCString { strdup($0)! } }
        defer { cArgs.forEach { free($0) } }
        var argvBuf = cArgs.map { Optional(UnsafeMutablePointer($0)) } + [nil]

        let cEnv = env.map { "\($0.key)=\($0.value)".withCString { strdup($0)! } }
        defer { cEnv.forEach { free($0) } }
        var envpBuf = cEnv.map { Optional(UnsafeMutablePointer($0)) } + [nil]

        // Set up pipe for stdout+stderr capture
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else {
            return (false, "Failed to create pipe")
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, pipeFDs[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, pipeFDs[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipeFDs[0])
        posix_spawn_file_actions_addclose(&fileActions, pipeFDs[1])

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, path, &fileActions, nil, &argvBuf, &envpBuf)
        close(pipeFDs[1])  // Close write end in parent

        guard spawnResult == 0 else {
            close(pipeFDs[0])
            return (false, "posix_spawn failed: \(spawnResult)")
        }

        // Read output
        let readFD = pipeFDs[0]
        var outputData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(readFD, &buf, buf.count)
            if n <= 0 { break }
            outputData.append(contentsOf: buf[0..<n])
        }
        close(readFD)

        // Wait for child — WIFEXITED/WEXITSTATUS are C macros, replicate manually
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let exited = (status & 0x7f) == 0
        let exitCode = exited ? (status >> 8) & 0xff : Int32(-1)

        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (exitCode == 0, output)
    }

    private func showStatus(_ text: String, isError: Bool) {
        let message = StatusMessage(text: text, isError: isError)
        statusMessage = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if statusMessage?.id == message.id {
                statusMessage = nil
            }
        }
    }
}

// MARK: - Status Message

private struct StatusMessage: Sendable {
    let id: UUID
    let text: String
    let isError: Bool

    init(text: String, isError: Bool) {
        self.id = UUID()
        self.text = text
        self.isError = isError
    }
}
