import SwiftUI
import UIKit

/// Simplified integration setup screen for the onboarding flow.
/// Shows cards for Claude Desktop, Claude Code, and OpenClaw
/// with one-click install or copy actions.
struct IntegrationSetupView: View {
    let onContinue: () -> Void

    @State private var claudeDesktopInstalled = false
    @State private var claudeCodeInstalled = false
    @State private var openClawInstalled = false
    @State private var nodeAvailable = false
    @State private var openClawDetected = false
    @State private var feedbackMessage: String?
    @State private var feedbackIsError = false

    // MARK: - Constants

    private static let serverName = "homeclaw"
    private static let legacyServerName = "homekit-bridge"
    private static let pluginPrefix = "homeclaw@"
    private static let legacyPluginPrefix = "homekit-bridge@"
    private static let githubRepo = "omarshahine/HomeClaw"
    private static let openClawPluginID = "homeclaw"

    private static var homebrewBinDir: String {
        #if arch(arm64)
        return "/opt/homebrew/bin"
        #else
        return "/usr/local/bin"
        #endif
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

    private static var bundledServerJSPath: String? {
        let path = Bundle.main.bundlePath + "/Contents/Resources/mcp-server.js"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private static var bundledOpenClawPluginPath: String? {
        let path = Bundle.main.bundlePath + "/Contents/Resources/openclaw"
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            ? path : nil
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 12) {
                Text("Set Up Integrations")
                    .font(.largeTitle.bold())

                Text("Connect HomeClaw to your AI tools. You can always set these up later in Settings.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            VStack(spacing: 12) {
                integrationCard(
                    icon: "bubble.left.and.bubble.right.fill",
                    title: "Claude Desktop",
                    subtitle: nodeAvailable
                        ? (claudeDesktopInstalled ? "MCP server installed" : "One-click MCP config install")
                        : "Requires Node.js",
                    isInstalled: claudeDesktopInstalled,
                    isAvailable: nodeAvailable && Self.bundledServerJSPath != nil
                ) {
                    installClaudeDesktop()
                }

                integrationCard(
                    icon: "terminal.fill",
                    title: "Claude Code",
                    subtitle: claudeCodeInstalled
                        ? "Plugin installed" : "Copy install command to clipboard",
                    isInstalled: claudeCodeInstalled,
                    isAvailable: true
                ) {
                    copyClaudeCodeInstallCommands()
                }

                integrationCard(
                    icon: "puzzlepiece.fill",
                    title: "OpenClaw",
                    subtitle: !openClawDetected
                        ? "Not detected"
                        : (openClawInstalled ? "Plugin installed" : "One-click install"),
                    isInstalled: openClawInstalled,
                    isAvailable: openClawDetected && Self.bundledOpenClawPluginPath != nil
                ) {
                    installOpenClaw()
                }
            }
            .frame(maxWidth: 440)

            if let message = feedbackMessage {
                Label(
                    message,
                    systemImage: feedbackIsError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .foregroundStyle(feedbackIsError ? .red : .green)
                .font(.subheadline)
            }

            Spacer()

            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 40)
        .onAppear { refreshStatuses() }
    }

    // MARK: - Card View

    @ViewBuilder
    private func integrationCard(
        icon: String,
        title: String,
        subtitle: String,
        isInstalled: Bool,
        isAvailable: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isInstalled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else if isAvailable {
                Button("Set Up") {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Status Checking

    private func refreshStatuses() {
        nodeAvailable = nodeJSPath() != nil
        claudeDesktopInstalled = checkClaudeDesktopInstalled()
        claudeCodeInstalled = checkClaudeCodeInstalled()
        let ocStatus = checkOpenClawStatus()
        openClawDetected = ocStatus.detected
        openClawInstalled = ocStatus.installed
    }

    private func checkClaudeDesktopInstalled() -> Bool {
        guard let data = FileManager.default.contents(atPath: Self.claudeDesktopConfigPath),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = config["mcpServers"] as? [String: Any]
        else { return false }
        return servers[Self.serverName] != nil || servers[Self.legacyServerName] != nil
    }

    private func checkClaudeCodeInstalled() -> Bool {
        guard let data = FileManager.default.contents(atPath: Self.claudeCodeSettingsPath),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = config["enabledPlugins"] as? [String: Any]
        else { return false }
        return enabled.keys.contains {
            $0.hasPrefix(Self.pluginPrefix) || $0.hasPrefix(Self.legacyPluginPrefix)
        }
    }

    private func checkOpenClawStatus() -> (detected: Bool, installed: Bool) {
        let configDir = (AppConfig.realHomeDirectory as NSString)
            .appendingPathComponent(".openclaw")
        guard FileManager.default.fileExists(atPath: configDir) else {
            return (false, false)
        }

        let extensionsPath = AppConfig.realHomeDirectory + "/.openclaw/extensions/homeclaw"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: extensionsPath, isDirectory: &isDir),
           isDir.boolValue
        {
            return (true, true)
        }
        return (true, false)
    }

    // MARK: - Install Actions

    private func installClaudeDesktop() {
        guard let serverJS = Self.bundledServerJSPath else {
            showFeedback("MCP server not bundled", isError: true)
            return
        }
        guard let nodePath = nodeJSPath() else {
            showFeedback("Node.js not found", isError: true)
            return
        }

        let entry: [String: Any] = [
            "command": nodePath,
            "args": [serverJS],
        ]

        do {
            var config = readConfig(at: Self.claudeDesktopConfigPath) ?? [:]
            var servers = config["mcpServers"] as? [String: Any] ?? [:]
            servers.removeValue(forKey: Self.legacyServerName)
            servers[Self.serverName] = entry
            config["mcpServers"] = servers
            try writeConfig(config, to: Self.claudeDesktopConfigPath)
            claudeDesktopInstalled = true
            showFeedback("Claude Desktop configured — restart Claude Desktop to connect", isError: false)
        } catch {
            showFeedback("Failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func copyClaudeCodeInstallCommands() {
        let commands = """
            /plugin marketplace add \(Self.githubRepo)
            /plugin install homeclaw@homeclaw
            """
        UIPasteboard.general.string = commands
        showFeedback("Install commands copied to clipboard", isError: false)
    }

    private func installOpenClaw() {
        guard let pluginPath = Self.bundledOpenClawPluginPath,
              let cliPath = openClawCLIPath()
        else {
            showFeedback("OpenClaw plugin or CLI not found", isError: true)
            return
        }

        let installResult = runProcess(cliPath, arguments: ["plugins", "install", pluginPath])
        guard installResult.success else {
            showFeedback("Install failed: \(installResult.output)", isError: true)
            return
        }

        let enableResult = runProcess(cliPath, arguments: ["plugins", "enable", Self.openClawPluginID])
        guard enableResult.success else {
            showFeedback("Enable failed: \(enableResult.output)", isError: true)
            return
        }

        // Symlink CLI
        let symlinkScript = """
            do shell script "ln -sf '\(Self.bundledCLIPath)' '\(Self.homebrewBinDir)/homeclaw-cli'" \
            with administrator privileges
            """
        _ = runAppleScript(symlinkScript)

        // Restart gateway
        _ = runProcess(cliPath, arguments: ["gateway", "restart"])

        openClawInstalled = true
        showFeedback("OpenClaw plugin installed", isError: false)
    }

    // MARK: - Helpers

    private func nodeJSPath() -> String? {
        ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]
            .first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private func openClawCLIPath() -> String? {
        ["/usr/local/bin/openclaw", "/opt/homebrew/bin/openclaw"]
            .first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private func readConfig(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func writeConfig(_ config: [String: Any], to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> Bool {
        runProcess("/usr/bin/osascript", arguments: ["-e", source]).success
    }

    private func runProcess(_ path: String, arguments: [String]) -> (success: Bool, output: String) {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")

        let cArgs = ([path] + arguments).map { $0.withCString { strdup($0)! } }
        defer { cArgs.forEach { free($0) } }
        var argvBuf = cArgs.map { Optional(UnsafeMutablePointer($0)) } + [nil]

        let cEnv = env.map { "\($0.key)=\($0.value)".withCString { strdup($0)! } }
        defer { cEnv.forEach { free($0) } }
        var envpBuf = cEnv.map { Optional(UnsafeMutablePointer($0)) } + [nil]

        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { return (false, "Failed to create pipe") }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, pipeFDs[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, pipeFDs[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipeFDs[0])
        posix_spawn_file_actions_addclose(&fileActions, pipeFDs[1])

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, path, &fileActions, nil, &argvBuf, &envpBuf)
        close(pipeFDs[1])

        guard spawnResult == 0 else {
            close(pipeFDs[0])
            return (false, "posix_spawn failed: \(spawnResult)")
        }

        let readFD = pipeFDs[0]
        var outputData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(readFD, &buf, buf.count)
            if n <= 0 { break }
            outputData.append(contentsOf: buf[0..<n])
        }
        close(readFD)

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let exited = (status & 0x7f) == 0
        let exitCode = exited ? (status >> 8) & 0xff : Int32(-1)

        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (exitCode == 0, output)
    }

    private func showFeedback(_ text: String, isError: Bool) {
        feedbackMessage = text
        feedbackIsError = isError
        Task {
            try? await Task.sleep(for: .seconds(4))
            if feedbackMessage == text {
                feedbackMessage = nil
            }
        }
    }
}
