import Foundation

/// Deny-by-default policy for which tools and actions the unauthenticated
/// loopback HTTP transport may expose.
///
/// Every exposed tool must be listed with an explicit action rule. A tool that
/// is not listed, an action that is not allowlisted, or an `action` argument
/// sent to a tool whose rule says it has none, is rejected in both `tools/list`
/// and `tools/call`. Adding a tool here without thinking about its actions
/// therefore fails closed rather than exposing its write paths.
struct HTTPToolPolicy: Sendable {
    enum Actions: Sendable, Equatable {
        /// The tool takes no `action` parameter. Its schema must not declare
        /// one and calls must not supply one.
        case none
        /// Only these actions are allowed. `defaultAction` is what the handler
        /// runs when the caller omits `action`; it must be in `allowed`.
        case allowlist(Set<String>, defaultAction: String)
    }

    /// How the HTTP copy of a descriptor differs from the canonical one, so
    /// clients are not told about actions or parameters HTTP rejects. The
    /// canonical (stdio) descriptors are never modified.
    struct DescriptorOverride: Sendable, Equatable {
        var description: String?
        var removedProperties: Set<String> = []
        var propertyDescriptions: [String: String] = [:]
    }

    struct Rule: Sendable, Equatable {
        let actions: Actions
        /// Whether the handler waits on HomeKit. Such calls are refused while
        /// HomeKit is not ready instead of parking on `waitForReady()`.
        let requiresHomeKit: Bool
        var descriptor: DescriptorOverride? = nil
    }

    let rules: [String: Rule]

    /// The read-only surface: no tool or action that mutates HomeKit or config.
    static let readOnly = HTTPToolPolicy(rules: [
        "homekit_status": Rule(actions: .none, requiresHomeKit: false),
        "homekit_accessories": Rule(
            actions: .allowlist(["list", "get", "search"], defaultAction: "list"),
            requiresHomeKit: true,
            descriptor: DescriptorOverride(
                description: "Read HomeKit accessories: list all, get details, or search by name/room/category. Read-only over this transport; control is not available. Returns only accessories visible under the current filter configuration. Defaults to configured home if home_id not specified.",
                removedProperties: ["characteristic", "value", "service_type", "service_name", "service_id", "service_index", "verify"],
                propertyDescriptions: ["accessory_id": "Accessory UUID or name (get action)"])),
        "homekit_rooms": Rule(actions: .none, requiresHomeKit: true),
        "homekit_device_map": Rule(actions: .none, requiresHomeKit: true),
        "homekit_events": Rule(actions: .none, requiresHomeKit: false),
    ])

    func rule(for name: String) -> Rule? { rules[name] }

    /// Filters a tool descriptor list to the allowed surface. Tools without a
    /// rule are dropped; allowlisted action enums are narrowed; a tool whose
    /// schema declares an `action` its rule does not account for is dropped.
    func advertisedTools(from tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool in
            guard let name = tool["name"] as? String, let rule = rules[name] else { return nil }
            let schema = tool["inputSchema"] as? [String: Any]
            let properties = schema?["properties"] as? [String: Any]
            let action = properties?["action"] as? [String: Any]
            guard let filtered = narrowActions(of: tool, rule: rule, schema: schema, properties: properties, action: action) else { return nil }
            return applying(rule.descriptor, to: filtered)
        }
    }

    private func narrowActions(of tool: [String: Any], rule: Rule, schema: [String: Any]?, properties: [String: Any]?, action: [String: Any]?) -> [String: Any]? {
        switch rule.actions {
        case .none:
            return action == nil ? tool : nil
        case .allowlist(let allowed, _):
            guard var schema, var properties, var action else {
                // An allowlisted tool must advertise its action enum; a
                // schema without one means the descriptors have drifted.
                return nil
            }
            guard let actions = action["enum"] as? [String] else { return nil }
            let narrowed = actions.filter(allowed.contains)
            guard !narrowed.isEmpty else { return nil }
            action["enum"] = narrowed
            properties["action"] = action
            schema["properties"] = properties
            var filtered = tool
            filtered["inputSchema"] = schema
            return filtered
        }
    }

    private func applying(_ override: DescriptorOverride?, to tool: [String: Any]) -> [String: Any] {
        guard let override else { return tool }
        var tool = tool
        if let description = override.description { tool["description"] = description }
        if var schema = tool["inputSchema"] as? [String: Any], var properties = schema["properties"] as? [String: Any] {
            override.removedProperties.forEach { properties.removeValue(forKey: $0) }
            for (name, text) in override.propertyDescriptions {
                guard var property = properties[name] as? [String: Any] else { continue }
                property["description"] = text
                properties[name] = property
            }
            schema["properties"] = properties
            if let required = schema["required"] as? [String] {
                schema["required"] = required.filter { !override.removedProperties.contains($0) }
            }
            tool["inputSchema"] = schema
        }
        return tool
    }

    /// Whether a `tools/call` for this tool and these arguments is allowed.
    func allowsCall(name: String, arguments: [String: Any]) -> Bool {
        guard let rule = rules[name] else { return false }
        switch rule.actions {
        case .none:
            return arguments["action"] == nil
        case .allowlist(let allowed, let defaultAction):
            guard let raw = arguments["action"] else { return allowed.contains(defaultAction) }
            guard let action = raw as? String else { return false }
            return allowed.contains(action)
        }
    }
}
