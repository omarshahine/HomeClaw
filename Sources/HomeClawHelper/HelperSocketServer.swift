import Foundation

/// Unix domain socket server for the HomeKit helper process.
/// Accepts JSON commands from the main app and CLI, routes to HomeKitManager.
///
/// Uses GCD (DispatchSource) for non-blocking socket I/O instead of POSIX accept(),
/// which would block a cooperative thread and cause issues with Swift concurrency.
final class HelperSocketServer: @unchecked Sendable {
    static let shared = HelperSocketServer()

    /// App Group identifier shared with the main app for sandboxed IPC.
    private static let appGroupID = "group.com.shahine.homeclaw"

    /// Socket path — uses App Group container when available (sandboxed builds),
    /// falls back to /tmp for Developer ID builds.
    static let socketPath: String = {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            return container.appendingPathComponent("homeclaw.sock").path
        }
        return "/tmp/homeclaw.sock"
    }()

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.shahine.homeclaw.helper.socket", qos: .userInitiated)

    /// Start the socket server synchronously (non-blocking — sets up GCD dispatch sources).
    func start() {
        let path = Self.socketPath

        // Remove stale socket
        unlink(path)

        // Create socket
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            HelperLogger.socket.error("Failed to create Unix socket")
            return
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = memcpy(ptr, cstr, min(path.utf8.count, MemoryLayout.size(ofValue: ptr.pointee) - 1))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            HelperLogger.socket.error("Failed to bind socket (errno: \(errno))")
            close(serverFD)
            return
        }

        // Listen
        guard listen(serverFD, 16) == 0 else {
            HelperLogger.socket.error("Failed to listen on socket (errno: \(errno))")
            close(serverFD)
            return
        }

        // Make socket world-accessible so the CLI and main app can connect
        chmod(path, 0o666)

        // Increase socket buffers for large responses (192 accessories = ~300KB JSON)
        var bufSize: Int32 = 1_048_576 // 1 MB
        setsockopt(serverFD, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(serverFD, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

        // Set non-blocking for the accept loop
        let flags = fcntl(serverFD, F_GETFL)
        _ = fcntl(serverFD, F_SETFL, flags | O_NONBLOCK)

        // Create GCD dispatch source to accept connections without blocking
        let source = DispatchSource.makeReadSource(fileDescriptor: serverFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.serverFD, fd >= 0 {
                close(fd)
            }
            unlink(Self.socketPath)
        }
        source.resume()
        acceptSource = source

        HelperLogger.socket.info("Socket server listening at \(path)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        serverFD = -1
    }

    // MARK: - Connection Handling

    private func acceptConnection() {
        let clientFD = accept(serverFD, nil, nil)
        guard clientFD >= 0 else { return }

        // On macOS, accept() inherits the non-blocking flag from the listening socket.
        // Reset the client FD to blocking so recv() waits for data instead of returning EAGAIN.
        let flags = fcntl(clientFD, F_GETFL)
        if flags != -1 {
            _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)
        }

        // Dispatch each client to a GCD thread for blocking I/O,
        // with async MainActor processing for HomeKit calls.
        let server = self
        DispatchQueue.global(qos: .userInitiated).async {
            server.readRequestAndRespond(fd: clientFD)
        }
    }

    /// Reads a request from the client fd, processes it via MainActor, and sends the response.
    /// Runs entirely on a GCD thread (blocking I/O is fine here).
    private func readRequestAndRespond(fd: Int32) {
        // Set large send buffer on the client socket for big responses
        var bufSize: Int32 = 1_048_576
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

        // Read request (up to 64KB)
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = recv(fd, &buffer, buffer.count, 0)
        guard bytesRead > 0 else {
            close(fd)
            return
        }

        let requestData = Data(buffer[..<bytesRead])

        // Find newline-delimited request
        let lineData: Data
        if let newlineIdx = requestData.firstIndex(of: UInt8(ascii: "\n")) {
            lineData = Data(requestData[requestData.startIndex..<newlineIdx])
        } else {
            lineData = requestData
        }

        // Bridge to MainActor for HomeKit processing, then send response on this thread.
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()

        Task { @MainActor in
            let result = await self.processRequest(lineData)
            box.value = result
            semaphore.signal()
        }
        semaphore.wait()

        sendResponse(box.value, to: fd)

        // Signal write-complete so the client sees a clean EOF before we close.
        // Without this, close() can race with the client's recv() on large responses.
        shutdown(fd, SHUT_WR)
        close(fd)
    }

    @MainActor
    private func processRequest(_ data: Data) async -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = json["command"] as? String
        else {
            return encodeResponse(success: false, error: "Invalid JSON request")
        }

        let args = json["args"] as? [String: Any] ?? [:]
        let hk = HomeKitManager.shared

        do {
            let result: Any

            switch command {
            case "status":
                let cacheInfo: [String: Any] = [
                    "cached_accessories": CharacteristicCache.shared.cachedAccessoryCount,
                    "is_stale": CharacteristicCache.shared.isStale,
                    "last_warmed": CharacteristicCache.shared.lastWarmedString as Any,
                ]
                result = [
                    "ready": hk.isReady,
                    "homes": hk.homes.count,
                    "accessories": hk.totalAccessoryCount,
                    "cache": cacheInfo,
                ] as [String: Any]

            case "list_homes":
                result = await hk.listHomes()

            case "list_accessories":
                result = await hk.listAccessories(
                    homeID: args["home_id"] as? String,
                    room: args["room"] as? String
                )

            case "list_all_accessories":
                result = await hk.listAllAccessories()

            case "get_accessory":
                guard let id = args["id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'id' argument")
                }
                guard let accessory = await hk.getAccessory(id: id, homeID: args["home_id"] as? String) else {
                    return encodeResponse(success: false, error: "Accessory not found: \(id)")
                }
                result = accessory

            case "control":
                guard let id = args["id"] as? String,
                      let characteristic = args["characteristic"] as? String,
                      let value = args["value"] as? String
                else {
                    return encodeResponse(success: false, error: "Missing id, characteristic, or value")
                }
                result = try await hk.controlAccessory(id: id, characteristic: characteristic, value: value, homeID: args["home_id"] as? String)

            case "list_rooms":
                result = await hk.listRooms(homeID: args["home_id"] as? String)

            case "list_scenes":
                result = await hk.listScenes(homeID: args["home_id"] as? String)

            case "trigger_scene":
                guard let id = args["id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'id' argument")
                }
                result = try await hk.triggerScene(id: id, homeID: args["home_id"] as? String)

            case "refresh_cache":
                result = await hk.refreshCache()

            case "device_map":
                result = await hk.deviceMap(homeID: args["home_id"] as? String)

            case "search":
                guard let query = args["query"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'query' argument")
                }
                result = await hk.searchAccessories(
                    query: query,
                    category: args["category"] as? String,
                    homeID: args["home_id"] as? String
                )

            case "get_config":
                // Return current config plus summary counts
                let homesList = await hk.listHomes()
                let allCount = hk.totalAccessoryCount
                let filteredCount: Int
                if HelperConfig.shared.filterMode == "allowlist",
                   let allowed = HelperConfig.shared.allowedIDs
                {
                    filteredCount = allowed.count
                } else {
                    filteredCount = allCount
                }
                result = [
                    "config": HelperConfig.shared.toDict(),
                    "available_homes": homesList,
                    "total_accessories": allCount,
                    "filtered_accessories": filteredCount,
                ] as [String: Any]

            case "set_config":
                if let homeID = args["default_home_id"] as? String {
                    if homeID.isEmpty || homeID.lowercased() == "none" {
                        HelperConfig.shared.defaultHomeID = nil
                    } else {
                        // Accept UUID or name — resolve name to UUID
                        let resolvedID: String
                        let allHomes = await hk.listHomes()
                        if let match = allHomes.first(where: {
                            ($0["id"] as? String) == homeID
                                || ($0["name"] as? String)?.localizedCaseInsensitiveCompare(homeID)
                                    == .orderedSame
                        }), let id = match["id"] as? String {
                            resolvedID = id
                        } else {
                            resolvedID = homeID
                        }
                        HelperConfig.shared.defaultHomeID = resolvedID
                    }
                }
                if let mode = args["accessory_filter_mode"] as? String {
                    HelperConfig.shared.filterMode = mode
                }
                if let ids = args["allowed_accessory_ids"] as? [String] {
                    HelperConfig.shared.setAllowedAccessories(ids)
                }
                if let unit = args["temperature_unit"] as? String {
                    let oldUnit = HelperConfig.shared.temperatureUnit
                    HelperConfig.shared.temperatureUnit = unit
                    // Invalidate cache when temperature unit changes so values get re-formatted
                    if HelperConfig.shared.temperatureUnit != oldUnit {
                        CharacteristicCache.shared.invalidateValues()
                        Task { let _ = await hk.refreshCache() }
                    }
                }
                result = HelperConfig.shared.toDict()

            default:
                return encodeResponse(success: false, error: "Unknown command: \(command)")
            }

            return encodeResponse(success: true, data: result)
        } catch {
            return encodeResponse(success: false, error: error.localizedDescription)
        }
    }

    // MARK: - Response Encoding

    private func encodeResponse(success: Bool, data: Any? = nil, error: String? = nil) -> String {
        var dict: [String: Any] = ["success": success]
        if let data { dict["data"] = data }
        if let error { dict["error"] = error }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let string = String(data: jsonData, encoding: .utf8)
        else {
            return #"{"success":false,"error":"Encoding failed"}"#
        }
        return string
    }

    private func sendResponse(_ response: String, to fd: Int32) {
        let responseWithNewline = response + "\n"
        let data = Array(responseWithNewline.utf8)
        var totalSent = 0
        while totalSent < data.count {
            let sent = data.withUnsafeBufferPointer { buffer in
                send(fd, buffer.baseAddress! + totalSent, data.count - totalSent, 0)
            }
            if sent <= 0 { break }
            totalSent += sent
        }
    }
}

// MARK: - Response Box

/// Thread-safe box for passing a response string between GCD and Task contexts.
/// The semaphore in the caller guarantees sequential access (write then read).
private final class ResponseBox: @unchecked Sendable {
    var value = ""
}

// MARK: - Errors

enum HelperError: Error, LocalizedError {
    case socketCreationFailed
    case bindFailed(Int32)
    case listenFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed: "Failed to create Unix socket"
        case .bindFailed(let code): "Failed to bind socket (errno: \(code))"
        case .listenFailed(let code): "Failed to listen on socket (errno: \(code))"
        }
    }
}
