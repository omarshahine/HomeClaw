import Foundation

/// Communicates with the HomeKit Helper (Catalyst) process via Unix domain socket.
/// Mirrors the HomeKitManager interface but proxies all calls through IPC.
///
/// Returns raw JSON `Data` from each method to avoid Swift 6 `Sendable` issues
/// with `[String: Any]`. Callers deserialize in their own isolation domain.
actor HomeKitClient {
    static let shared = HomeKitClient()

    /// The socket path where the helper process listens.
    private let socketPath = AppConfig.socketPath

    // MARK: - Status

    struct Status: Sendable {
        let ready: Bool
        let homeCount: Int
        let accessoryCount: Int
    }

    func status() async throws -> Status {
        let json = try await sendRaw(command: "status", args: [:])
        guard let data = json["data"] as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return Status(
            ready: (data["ready"] as? Bool) ?? false,
            homeCount: (data["homes"] as? Int) ?? 0,
            accessoryCount: (data["accessories"] as? Int) ?? 0
        )
    }

    var isReady: Bool {
        get async {
            (try? await status().ready) ?? false
        }
    }

    // MARK: - Commands (return raw JSON Data for Sendable safety)

    func listHomes() async throws -> sending Data {
        try await sendCommandData("list_homes")
    }

    func listRooms(homeID: String? = nil) async throws -> sending Data {
        var args: [String: Any] = [:]
        if let homeID { args["home_id"] = homeID }
        return try await sendCommandData("list_rooms", args: args)
    }

    func listAccessories(homeID: String? = nil, room: String? = nil) async throws -> sending Data {
        var args: [String: Any] = [:]
        if let homeID { args["home_id"] = homeID }
        if let room { args["room"] = room }
        return try await sendCommandData("list_accessories", args: args)
    }

    func getAccessory(id: String) async throws -> sending Data? {
        do {
            return try await sendCommandData("get_accessory", args: ["id": id])
        } catch ClientError.helperError(let msg) where msg.contains("not found") {
            return nil
        }
    }

    func controlAccessory(id: String, characteristic: String, value: String) async throws -> sending Data {
        try await sendCommandData("control", args: [
            "id": id,
            "characteristic": characteristic,
            "value": value,
        ])
    }

    func listScenes(homeID: String? = nil) async throws -> sending Data {
        var args: [String: Any] = [:]
        if let homeID { args["home_id"] = homeID }
        return try await sendCommandData("list_scenes", args: args)
    }

    func triggerScene(id: String) async throws -> sending Data {
        try await sendCommandData("trigger_scene", args: ["id": id])
    }

    func searchAccessories(query: String, category: String? = nil) async throws -> sending Data {
        var args: [String: Any] = ["query": query]
        if let category { args["category"] = category }
        return try await sendCommandData("search", args: args)
    }

    func deviceMap(homeID: String? = nil) async throws -> sending Data {
        var args: [String: Any] = [:]
        if let homeID { args["home_id"] = homeID }
        return try await sendCommandData("device_map", args: args)
    }

    func listAllAccessories() async throws -> sending Data {
        try await sendCommandData("list_all_accessories")
    }

    func getConfig() async throws -> sending Data {
        try await sendCommandData("get_config")
    }

    func setConfig(
        defaultHomeID: String? = nil,
        filterMode: String? = nil,
        allowedAccessoryIDs: [String]? = nil
    ) async throws -> sending Data {
        var args: [String: Any] = [:]
        if let defaultHomeID {
            args["default_home_id"] = defaultHomeID
        }
        if let filterMode {
            args["accessory_filter_mode"] = filterMode
        }
        if let allowedAccessoryIDs {
            args["allowed_accessory_ids"] = allowedAccessoryIDs
        }
        return try await sendCommandData("set_config", args: args)
    }

    // MARK: - Socket Communication

    enum ClientError: Error, LocalizedError, Sendable {
        case socketNotAvailable
        case connectionFailed(String)
        case sendFailed
        case invalidResponse
        case helperError(String)

        var errorDescription: String? {
            switch self {
            case .socketNotAvailable: "Helper not running (socket not found)"
            case .connectionFailed(let msg): "Connection failed: \(msg)"
            case .sendFailed: "Failed to send command to helper"
            case .invalidResponse: "Invalid response from helper"
            case .helperError(let msg): msg
            }
        }
    }

    /// Sends a command and returns the `data` field as serialized JSON Data.
    private func sendCommandData(_ command: String, args: [String: Any] = [:]) async throws -> Data {
        let json = try await sendRaw(command: command, args: args)
        guard let data = json["data"] else {
            throw ClientError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
    }

    /// Low-level socket communication with the helper process.
    private func sendRaw(command: String, args: [String: Any]) async throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw ClientError.socketNotAvailable
        }

        // Build JSON request
        var request: [String: Any] = ["command": command]
        if !args.isEmpty { request["args"] = args }

        let requestData = try JSONSerialization.data(withJSONObject: request)
        guard var requestString = String(data: requestData, encoding: .utf8) else {
            throw ClientError.sendFailed
        }
        requestString += "\n"

        // Connect via Unix domain socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClientError.connectionFailed("socket() failed: errno \(errno)")
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = memcpy(ptr, cstr, min(socketPath.utf8.count, MemoryLayout.size(ofValue: ptr.pointee) - 1))
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw ClientError.connectionFailed("connect() failed: errno \(errno)")
        }

        // Send
        let sent = requestString.withCString { ptr in
            send(fd, ptr, requestString.utf8.count, 0)
        }
        guard sent > 0 else {
            throw ClientError.sendFailed
        }

        // Receive response — loop until we see a trailing newline delimiter.
        // Responses can be large (100s of KB for full accessory lists).
        var responseData = Data()
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            let received = recv(fd, &buffer, bufferSize, 0)
            if received <= 0 { break }
            responseData.append(contentsOf: buffer[..<received])
            if responseData.last == UInt8(ascii: "\n") { break }
        }

        guard !responseData.isEmpty else {
            throw ClientError.invalidResponse
        }

        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw ClientError.invalidResponse
        }

        // Check for errors
        if let success = json["success"] as? Bool, !success {
            let errorMsg = json["error"] as? String ?? "Unknown helper error"
            throw ClientError.helperError(errorMsg)
        }

        return json
    }
}
