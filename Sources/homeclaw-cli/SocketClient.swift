import Foundation

/// Connects to the HomeClaw app via Unix domain socket.
enum SocketClient {
    /// App Group identifier shared with the main app and helper.
    private static let appGroupID = "group.com.shahine.homeclaw"

    /// Socket path — checks App Group container first (for App Store builds),
    /// then falls back to /tmp (Developer ID builds).
    static let socketPath: String = {
        // App Group container: ~/Library/Group Containers/group.com.shahine.homeclaw/
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            let groupPath = container.appendingPathComponent("homeclaw.sock").path
            if FileManager.default.fileExists(atPath: groupPath) {
                return groupPath
            }
        }
        return "/tmp/homeclaw.sock"
    }()

    struct CLIRequest: Codable {
        let command: String
        var args: [String: String]?
    }

    struct CLIResponse: Codable {
        let success: Bool
        let data: AnyCodable?
        let error: String?
    }

    enum ClientError: Error, LocalizedError {
        case appNotRunning
        case connectionFailed(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .appNotRunning:
                "HomeClaw is not running. Launch the app first."
            case .connectionFailed(let reason):
                "Connection failed: \(reason)"
            case .invalidResponse:
                "Invalid response from app"
            }
        }
    }

    /// Sends a command with string args to the running app and returns the response.
    static func send(command: String, args: [String: String]? = nil) throws -> CLIResponse {
        var anyArgs: [String: Any]?
        if let args { anyArgs = args }
        return try sendAny(command: command, args: anyArgs)
    }

    /// Sends a command with mixed-type args (supports arrays) to the running app.
    static func sendAny(command: String, args: [String: Any]? = nil) throws -> CLIResponse {
        // Check if socket exists
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw ClientError.appNotRunning
        }

        // Create Unix socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClientError.connectionFailed("Cannot create socket")
        }
        defer { close(fd) }

        // Connect
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
            throw ClientError.appNotRunning
        }

        // Send request using JSONSerialization for mixed-type args
        var request: [String: Any] = ["command": command]
        if let args { request["args"] = args }
        var requestData = try JSONSerialization.data(withJSONObject: request)
        requestData.append(contentsOf: "\n".utf8)

        _ = requestData.withUnsafeBytes { buffer in
            Darwin.send(fd, buffer.baseAddress!, buffer.count, 0)
        }

        // Read response — loop until we see a trailing newline delimiter.
        // Responses can be large (100s of KB for full accessory lists).
        var responseData = Data()
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            let bytesRead = recv(fd, &buffer, bufferSize, 0)
            if bytesRead <= 0 { break }
            responseData.append(contentsOf: buffer[..<bytesRead])
            // The response is newline-terminated; check if we've received the end
            if responseData.last == UInt8(ascii: "\n") { break }
        }

        guard !responseData.isEmpty else {
            throw ClientError.invalidResponse
        }

        return try JSONDecoder().decode(CLIResponse.self, from: responseData)
    }
}

// MARK: - AnyCodable (shared with app)

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) { value = str }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map(\.value)
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let str as String: try container.encode(str)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let bool as Bool: try container.encode(bool)
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
