import Foundation

/// The single registration/dispatch seam shared by native MCP transport and HomeKit.
protocol MCPToolRegistry: Sendable {
    var toolsJSON: Data { get }
    func call(name: String, arguments: Data) async -> Data
}

struct HomeClawMCPToolRegistry: MCPToolRegistry {
    static let shared = HomeClawMCPToolRegistry()

    let toolsJSON: Data = ToolHandlers.allToolsJSON

    func call(name: String, arguments: Data) async -> Data {
        await ToolHandlers.call(name: name, arguments: arguments)
    }
}

#if DEBUG
extension HomeClawMCPToolRegistry {
    static func test(status: String) -> MCPToolRegistry { TestMCPToolRegistry(status: status) }
}
private struct TestMCPToolRegistry: MCPToolRegistry {
    let status: String
    var toolsJSON: Data { Data("[{\"name\":\"homekit_status\"}]".utf8) }
    func call(name: String, arguments: Data) async -> Data { Data("{\"status\":\"\(status)\"}".utf8) }
}
#endif
