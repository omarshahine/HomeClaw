import Foundation

/// Read-only channel metadata shared by accessory summaries and discovery.
/// Values are last-known service values, never the accessory-wide collapsed cache.
enum ServiceDiscovery {
    struct Service: Sendable {
        let id: String
        let name: String
        let category: String?
        let displayAs: String?
        let index: Int?
        let controllable: Bool
        let state: [String: String]
    }

    static func controllableServices(_ services: [Service]) -> [Service] {
        services.filter { $0.controllable && $0.category != nil }
    }

    /// Single-channel accessories keep their existing compact summary shape.
    static func summaries(_ services: [Service]) -> [[String: Any]] {
        let channels = controllableServices(services)
        guard channels.count > 1 else { return [] }
        return channels.map { service in
            var row: [String: Any] = ["id": service.id, "name": service.name, "category": service.category!]
            if let index = service.index { row["index"] = index }
            if let displayAs = service.displayAs { row["display_as"] = displayAs }
            if !service.state.isEmpty {
                row["state"] = service.state
                row["state_source"] = "last_known"
            }
            return row
        }
    }

    static func aliases(_ services: [Service]) -> [String] {
        var seen = Set<String>()
        return controllableServices(services).compactMap { service in
            let name = service.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !name.isEmpty && seen.insert(name).inserted ? name : nil
        }
    }

    static func matchesCategory(_ requested: String, accessoryCategory: String, services: [Service]) -> Bool {
        let requested = requested.lowercased()
        if accessoryCategory.lowercased() == requested { return true }
        return controllableServices(services).contains { service in
            let displayedCategory = service.displayAs == "light" ? "lightbulb" : service.displayAs
            return service.category?.lowercased() == requested || displayedCategory?.lowercased() == requested
        }
    }
}
