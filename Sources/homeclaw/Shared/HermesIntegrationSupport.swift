import Foundation

/// Pure formatting and discovery helpers for the Hermes integration UI.
enum HermesIntegrationSupport {
    static let serverName = "homeclaw"

    static func mcpConfiguration(nodePath: String, serverPath: String) -> String {
        let config: [String: Any] = [
            "mcpServers": [
                serverName: [
                    "type": "stdio",
                    "command": nodePath,
                    "args": [serverPath],
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: data, encoding: .utf8)
        else { return "" }
        return result + "\n"
    }

    static func setupInstructions(nodePath: String, serverPath: String) -> String {
        "# HomeClaw → Hermes\n"
            + "# Start the HomeClaw app first, then add the JSON below to Hermes' MCP configuration.\n"
            + "# No sudo, symlink, credentials, or HomeKit write operation is required.\n"
            + mcpConfiguration(nodePath: nodePath, serverPath: serverPath)
    }

    static func findHermesExecutable(fileManager: FileManager = .default) -> String? {
        [
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
            "/usr/bin/hermes",
        ].first(where: { fileManager.isExecutableFile(atPath: $0) })
    }
}
