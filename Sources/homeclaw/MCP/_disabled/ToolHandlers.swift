import Foundation
import MCP

/// Registers all HomeKit MCP tools on the given server.
enum ToolHandlers {
    static func register(on server: Server) async {
        // Register tool listing
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: allTools)
        }

        // Register tool execution
        await server.withMethodHandler(CallTool.self) { params in
            await handleToolCall(params)
        }
    }

    // MARK: - Tool Definitions

    static let allTools: [Tool] = [
        Tool(
            name: "list_homes",
            description: "List all HomeKit homes with room and accessory counts",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        Tool(
            name: "list_accessories",
            description: "List HomeKit accessories with their current state. Returns only accessories visible under the current filter configuration. Optionally filter by home or room.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "home_id": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Filter by home UUID. Defaults to configured home if not specified."),
                    ]),
                    "room": .object([
                        "type": .string("string"),
                        "description": .string("Filter by room name (optional)"),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "get_accessory",
            description: "Get full details of a specific accessory including all services and characteristics. Accepts UUID or name. Restricted to accessories in the allow-list when filtering is enabled.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "accessory_id": .object([
                        "type": .string("string"),
                        "description": .string("Accessory UUID or name"),
                    ])
                ]),
                "required": .array([.string("accessory_id")]),
            ])
        ),
        Tool(
            name: "control_accessory",
            description: "Set a characteristic value on an accessory. Control is restricted to accessories in the allow-list when filtering is enabled. For example: set power to true, brightness to 75, target_temperature to 72.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "accessory_id": .object([
                        "type": .string("string"),
                        "description": .string("Accessory UUID or name"),
                    ]),
                    "characteristic": .object([
                        "type": .string("string"),
                        "description": .string("Characteristic name (e.g., 'power', 'brightness', 'target_temperature')"),
                    ]),
                    "value": .object([
                        "type": .string("string"),
                        "description": .string("Value to set (e.g., 'true', '75', 'locked')"),
                    ]),
                ]),
                "required": .array([.string("accessory_id"), .string("characteristic"), .string("value")]),
            ])
        ),
        Tool(
            name: "list_rooms",
            description: "List all rooms and their accessories. Optionally filter by home.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "home_id": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Filter by home UUID. Defaults to configured home if not specified."),
                    ])
                ]),
            ])
        ),
        Tool(
            name: "list_scenes",
            description: "List all scenes (action sets). Optionally filter by home.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "home_id": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Filter by home UUID. Defaults to configured home if not specified."),
                    ])
                ]),
            ])
        ),
        Tool(
            name: "trigger_scene",
            description: "Execute a scene by UUID or name.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "scene_id": .object([
                        "type": .string("string"),
                        "description": .string("Scene UUID or name"),
                    ])
                ]),
                "required": .array([.string("scene_id")]),
            ])
        ),
        Tool(
            name: "search_accessories",
            description: "Search accessories by name, room, category, semantic type, manufacturer, or natural-language aliases. Results include semantic_type, display_name, and manufacturer. Results are filtered by the current device allow-list configuration.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search query (matches name, room, category, semantic type, manufacturer, aliases like 'kitchen light')"),
                    ]),
                    "category": .object([
                        "type": .string("string"),
                        "description": .string("Filter by category (e.g., 'lightbulb', 'lock', 'thermostat')"),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        Tool(
            name: "device_map",
            description: "Get an LLM-optimized device map organized by home/zone/room with semantic types, auto-generated aliases, controllable characteristics, and state summaries. Use this to understand the full device landscape before controlling devices.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "home_id": .object([
                        "type": .string("string"),
                        "description": .string("Filter by home UUID. Defaults to configured home if not specified."),
                    ]),
                ]),
            ])
        ),
    ]

    // MARK: - Tool Execution

    private static func handleToolCall(_ params: CallTool.Parameters) async -> CallTool.Result {
        let hk = HomeKitClient.shared

        do {
            let jsonData: Data
            switch params.name {
            case "list_homes":
                jsonData = try await hk.listHomes()

            case "list_accessories":
                let homeID = params.arguments?["home_id"]?.stringValue
                let room = params.arguments?["room"]?.stringValue
                jsonData = try await hk.listAccessories(homeID: homeID, room: room)

            case "get_accessory":
                guard let id = params.arguments?["accessory_id"]?.stringValue else {
                    return errorResult("Missing required parameter: accessory_id")
                }
                guard let data = try await hk.getAccessory(id: id) else {
                    return errorResult("Accessory not found: \(id)", code: "ACCESSORY_NOT_FOUND")
                }
                jsonData = data

            case "control_accessory":
                guard let id = params.arguments?["accessory_id"]?.stringValue,
                      let characteristic = params.arguments?["characteristic"]?.stringValue,
                      let value = params.arguments?["value"]?.stringValue
                else {
                    return errorResult("Missing required parameters: accessory_id, characteristic, value")
                }
                jsonData = try await hk.controlAccessory(id: id, characteristic: characteristic, value: value)

            case "list_rooms":
                let homeID = params.arguments?["home_id"]?.stringValue
                jsonData = try await hk.listRooms(homeID: homeID)

            case "list_scenes":
                let homeID = params.arguments?["home_id"]?.stringValue
                jsonData = try await hk.listScenes(homeID: homeID)

            case "trigger_scene":
                guard let id = params.arguments?["scene_id"]?.stringValue else {
                    return errorResult("Missing required parameter: scene_id")
                }
                jsonData = try await hk.triggerScene(id: id)

            case "search_accessories":
                guard let query = params.arguments?["query"]?.stringValue else {
                    return errorResult("Missing required parameter: query")
                }
                let category = params.arguments?["category"]?.stringValue
                jsonData = try await hk.searchAccessories(query: query, category: category)

            case "device_map":
                let homeID = params.arguments?["home_id"]?.stringValue
                jsonData = try await hk.deviceMap(homeID: homeID)

            default:
                return errorResult("Unknown tool: \(params.name)", code: "UNKNOWN_TOOL")
            }

            // Pretty-print the JSON for readability in Claude's output
            if let obj = try? JSONSerialization.jsonObject(with: jsonData),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: pretty, encoding: .utf8)
            {
                return CallTool.Result(content: [.text(text)], isError: false)
            }

            let text = String(data: jsonData, encoding: .utf8) ?? "{}"
            return CallTool.Result(content: [.text(text)], isError: false)

        } catch let error as HomeKitClient.ClientError {
            return errorResult(error.localizedDescription, code: clientErrorCode(error))
        } catch {
            return errorResult(error.localizedDescription, code: "INTERNAL_ERROR")
        }
    }

    private static func errorResult(_ message: String, code: String? = nil) -> CallTool.Result {
        var text = message
        if let code {
            text = "[\(code)] \(message)"
        }
        return CallTool.Result(content: [.text(text)], isError: true)
    }

    private static func clientErrorCode(_ error: HomeKitClient.ClientError) -> String {
        switch error {
        case .socketNotAvailable: "HELPER_NOT_RUNNING"
        case .connectionFailed: "CONNECTION_FAILED"
        case .sendFailed: "SEND_FAILED"
        case .invalidResponse: "INVALID_RESPONSE"
        case .helperError(let msg):
            if msg.contains("not found") { "ACCESSORY_NOT_FOUND" }
            else if msg.contains("unreachable") { "ACCESSORY_UNREACHABLE" }
            else if msg.contains("not writable") { "CHARACTERISTIC_NOT_WRITABLE" }
            else { "HELPER_ERROR" }
        }
    }
}
