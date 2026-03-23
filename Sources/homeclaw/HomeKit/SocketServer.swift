import Foundation

/// Unix domain socket server for HomeKit IPC.
/// Accepts JSON commands from the CLI and MCP server, routes to HomeKitManager.
///
/// Uses GCD (DispatchSource) for non-blocking socket I/O instead of POSIX accept(),
/// which would block a cooperative thread and cause issues with Swift concurrency.
final class SocketServer: @unchecked Sendable {
    static let shared = SocketServer()

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.shahine.homeclaw.socket", qos: .userInitiated)

    private func parseBool(_ args: [String: Any], key: String, default defaultValue: Bool = false) -> Bool {
        (args[key] as? Bool) ?? (args[key] as? String).map { $0 == "true" } ?? defaultValue
    }

    /// Start the socket server synchronously (non-blocking — sets up GCD dispatch sources).
    func start() {
        let path = AppConfig.socketPath

        // Remove stale socket
        unlink(path)

        // Create socket
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            AppLogger.socket.error("Failed to create Unix socket")
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
            AppLogger.socket.error("Failed to bind socket (errno: \(errno))")
            close(serverFD)
            return
        }

        // Listen
        guard listen(serverFD, 16) == 0 else {
            AppLogger.socket.error("Failed to listen on socket (errno: \(errno))")
            close(serverFD)
            return
        }

        // Make socket world-accessible so the CLI and MCP server can connect
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
            unlink(AppConfig.socketPath)
        }
        source.resume()
        acceptSource = source

        AppLogger.socket.info("Socket server listening at \(path)")
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

        // Read request — loop until newline delimiter or 1MB cap.
        // A single recv() may not return the full payload for large requests
        // (e.g., import-scene with many actions).
        let maxRequestSize = 1_048_576 // 1 MB safety cap
        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)

        while requestData.count < maxRequestSize {
            let bytesRead = recv(fd, &buffer, buffer.count, 0)
            if bytesRead <= 0 { break }
            // Check the fresh chunk for the newline delimiter before appending,
            // avoiding an O(n²) rescan of the full accumulated buffer.
            let hasNewline = buffer[..<bytesRead].contains(UInt8(ascii: "\n"))
            requestData.append(contentsOf: buffer[..<bytesRead])
            if hasNewline { break }
        }

        guard !requestData.isEmpty else {
            close(fd)
            return
        }

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
                let formatter = ISO8601DateFormatter()
                let cb = WebhookCircuitBreaker.shared
                let webhookConfig = HomeClawConfig.shared.webhookConfig
                var webhookInfo: [String: Any] = [
                    "enabled": webhookConfig?.enabled ?? false,
                    "url": webhookConfig?.url ?? "",
                    "url_configured": !(webhookConfig?.url.isEmpty ?? true),
                    "circuit_state": cb.state.rawValue,
                    "consecutive_failures": cb.consecutiveFailures,
                    "total_delivered": cb.totalDeliveredCount,
                    "total_dropped": cb.totalDroppedCount,
                ]
                if cb.state != .closed {
                    webhookInfo["soft_trip_count"] = cb.softTripCount
                    webhookInfo["remaining_seconds"] = cb.remainingCooldownSeconds
                }
                if let status = cb.lastHTTPStatus { webhookInfo["last_http_status"] = status }
                if let d = cb.lastSuccessDate { webhookInfo["last_success"] = formatter.string(from: d) }
                if let d = cb.lastFailureDate { webhookInfo["last_failure"] = formatter.string(from: d) }

                result = [
                    "ready": hk.isReady,
                    "homes": hk.homes.count,
                    "accessories": hk.totalAccessoryCount,
                    "cache": cacheInfo,
                    "webhook": webhookInfo,
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
                result = try await hk.controlAccessory(
                    id: id, characteristic: characteristic, value: value,
                    homeID: args["home_id"] as? String,
                    serviceType: args["service_type"] as? String,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "list_rooms":
                result = await hk.listRooms(homeID: args["home_id"] as? String)

            case "list_scenes":
                result = await hk.listScenes(homeID: args["home_id"] as? String)

            case "get_scene":
                guard let id = args["id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'id' argument")
                }
                result = try await hk.getScene(id: id, homeID: args["home_id"] as? String)

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
                if HomeClawConfig.shared.filterMode == "allowlist",
                   let allowed = HomeClawConfig.shared.allowedIDs
                {
                    filteredCount = allowed.count
                } else {
                    filteredCount = allCount
                }
                result = [
                    "config": HomeClawConfig.shared.toDict(),
                    "available_homes": homesList,
                    "total_accessories": allCount,
                    "filtered_accessories": filteredCount,
                ] as [String: Any]

            case "set_config":
                if let homeID = args["default_home_id"] as? String {
                    if homeID.isEmpty || homeID.lowercased() == "none" {
                        HomeClawConfig.shared.defaultHomeID = nil
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
                        HomeClawConfig.shared.defaultHomeID = resolvedID
                    }
                }
                if let mode = args["accessory_filter_mode"] as? String {
                    HomeClawConfig.shared.filterMode = mode
                }
                if let ids = args["allowed_accessory_ids"] as? [String] {
                    HomeClawConfig.shared.setAllowedAccessories(ids)
                }
                if let unit = args["temperature_unit"] as? String {
                    let oldUnit = HomeClawConfig.shared.temperatureUnit
                    HomeClawConfig.shared.temperatureUnit = unit
                    // Invalidate cache when temperature unit changes so values get re-formatted
                    if HomeClawConfig.shared.temperatureUnit != oldUnit {
                        CharacteristicCache.shared.invalidateValues()
                        Task { let _ = await hk.refreshCache() }
                    }
                }
                result = HomeClawConfig.shared.toDict()

            case "events":
                let limit = (args["limit"] as? Int) ?? (args["limit"] as? String).flatMap(Int.init) ?? 100
                let typeFilter: HomeEventLogger.EventType? = (args["type"] as? String).flatMap {
                    HomeEventLogger.EventType(rawValue: $0)
                }
                var since: Date?
                if let sinceStr = args["since"] as? String {
                    since = ISO8601DateFormatter().date(from: sinceStr)
                }
                result = [
                    "events": HomeEventLogger.shared.readEvents(since: since, limit: limit, type: typeFilter),
                ] as [String: Any]

            case "set_webhook":
                // Merge provided fields into existing config (PATCH, not PUT).
                // Missing fields retain their current values.
                let existing = HomeClawConfig.shared.webhookConfig
                let enabled = (args["enabled"] as? Bool)
                    ?? (args["enabled"] as? String).map { $0 == "true" }
                    ?? existing?.enabled ?? false
                let url = (args["url"] as? String) ?? existing?.url ?? ""
                let token = (args["token"] as? String) ?? existing?.token ?? ""
                let events = (args["events"] as? [String]) ?? existing?.events
                let endpoint = (args["webhook_endpoint"] as? String) ?? existing?.webhookEndpoint
                HomeClawConfig.shared.webhookConfig = HomeClawConfig.WebhookConfig(
                    enabled: enabled, url: url, token: token, events: events,
                    webhookEndpoint: endpoint
                )
                // Full reset (including counters) when re-enabling webhook
                if enabled && WebhookCircuitBreaker.shared.state == .hardOpen {
                    WebhookCircuitBreaker.shared.fullReset()
                }
                result = HomeClawConfig.shared.toDict()

            case "webhook_test":
                guard let webhook = HomeClawConfig.shared.webhookConfig,
                      !webhook.url.isEmpty
                else {
                    return encodeResponse(success: false, error: "Webhook URL is not configured")
                }
                let baseURL = webhook.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let testURL = URL(string: baseURL + HomeClawConfig.shared.effectiveEndpoint) else {
                    return encodeResponse(success: false, error: "Invalid webhook URL: \(baseURL)")
                }
                let testPayload: [String: Any] = [
                    "text": "[HomeClaw] Webhook test event",
                    "mode": "now",
                ]
                guard let body = try? JSONSerialization.data(withJSONObject: testPayload) else {
                    return encodeResponse(success: false, error: "Failed to serialize test payload")
                }
                var testRequest = URLRequest(url: testURL)
                testRequest.httpMethod = "POST"
                testRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !webhook.token.isEmpty {
                    testRequest.setValue("Bearer \(webhook.token)", forHTTPHeaderField: "Authorization")
                }
                testRequest.httpBody = body
                testRequest.timeoutInterval = 10
                do {
                    let (responseData, response) = try await URLSession.shared.data(for: testRequest)
                    let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let responseBody = String(data: responseData.prefix(1024), encoding: .utf8) ?? ""
                    // Update circuit breaker stats so test results are visible in status
                    if httpStatus >= 400 {
                        WebhookCircuitBreaker.shared.recordFailure(httpStatus: httpStatus)
                    } else {
                        WebhookCircuitBreaker.shared.recordSuccess(httpStatus: httpStatus)
                    }
                    result = [
                        "url": testURL.absoluteString,
                        "status": httpStatus,
                        "ok": httpStatus >= 200 && httpStatus < 400,
                        "body": responseBody,
                    ] as [String: Any]
                } catch {
                    WebhookCircuitBreaker.shared.recordFailure()
                    result = [
                        "url": testURL.absoluteString,
                        "status": 0,
                        "ok": false,
                        "error": error.localizedDescription,
                    ] as [String: Any]
                }

            case "webhook_reset":
                WebhookCircuitBreaker.shared.manualReset()
                let cb = WebhookCircuitBreaker.shared
                result = [
                    "circuit_state": cb.state.rawValue,
                    "message": "Circuit breaker reset to closed",
                ] as [String: Any]

            case "event_log_stats":
                result = HomeEventLogger.shared.logStats()

            case "set_event_log":
                if let enabled = (args["enabled"] as? Bool)
                    ?? (args["enabled"] as? String).map({ $0 == "true" })
                {
                    HomeClawConfig.shared.eventLogEnabled = enabled
                }
                if let maxSizeMB = (args["max_size_mb"] as? Int)
                    ?? (args["max_size_mb"] as? String).flatMap(Int.init)
                {
                    HomeClawConfig.shared.eventLogMaxSizeMB = maxSizeMB
                }
                if let maxBackups = (args["max_backups"] as? Int)
                    ?? (args["max_backups"] as? String).flatMap(Int.init)
                {
                    HomeClawConfig.shared.eventLogMaxBackups = maxBackups
                }
                result = HomeEventLogger.shared.logStats()

            case "purge_events":
                HomeEventLogger.shared.purge()
                result = HomeEventLogger.shared.logStats()

            case "list_triggers":
                let triggers = HomeClawConfig.shared.webhookTriggers
                result = ["triggers": triggers.map { triggerToDict($0) }] as [String: Any]

            case "add_trigger":
                guard let label = args["label"] as? String, !label.isEmpty else {
                    return encodeResponse(success: false, error: "Missing 'label' argument")
                }
                var trigger = HomeClawConfig.WebhookTrigger.create(label: label)
                trigger.accessoryID = args["accessory_id"] as? String
                trigger.sceneName = args["scene_name"] as? String
                trigger.sceneID = args["scene_id"] as? String
                trigger.characteristic = args["characteristic"] as? String
                trigger.value = args["value"] as? String
                trigger.message = args["message"] as? String
                trigger.action = args["action"] as? String
                trigger.wakeMode = args["wake_mode"] as? String
                trigger.agentPrompt = args["agent_prompt"] as? String
                trigger.agentId = args["agent_id"] as? String
                trigger.agentName = args["agent_name"] as? String
                trigger.agentDeliver = args["agent_deliver"] as? Bool
                    ?? (args["agent_deliver"] as? String).map { $0 == "true" }
                HomeClawConfig.shared.addWebhookTrigger(trigger)
                result = triggerToDict(trigger)

            case "remove_trigger":
                guard let id = args["id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'id' argument")
                }
                HomeClawConfig.shared.removeWebhookTrigger(id: id)
                let triggers = HomeClawConfig.shared.webhookTriggers
                result = ["triggers": triggers.map { triggerToDict($0) }] as [String: Any]

            case "update_trigger":
                guard let id = args["id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'id' argument")
                }
                guard var trigger = HomeClawConfig.shared.webhookTriggers.first(where: { $0.id == id }) else {
                    return encodeResponse(success: false, error: "Trigger not found: \(id)")
                }
                if let v = args["label"] as? String { trigger.label = v }
                if let v = args["enabled"] as? Bool { trigger.enabled = v }
                else if let v = (args["enabled"] as? String).map({ $0 == "true" }) { trigger.enabled = v }
                if let v = args["accessory_id"] as? String { trigger.accessoryID = v.isEmpty ? nil : v }
                if let v = args["scene_name"] as? String { trigger.sceneName = v.isEmpty ? nil : v }
                if let v = args["scene_id"] as? String { trigger.sceneID = v.isEmpty ? nil : v }
                if let v = args["characteristic"] as? String { trigger.characteristic = v.isEmpty ? nil : v }
                if let v = args["value"] as? String { trigger.value = v.isEmpty ? nil : v }
                if let v = args["message"] as? String { trigger.message = v.isEmpty ? nil : v }
                if let v = args["action"] as? String { trigger.action = v.isEmpty ? nil : v }
                if let v = args["wake_mode"] as? String { trigger.wakeMode = v.isEmpty ? nil : v }
                if let v = args["agent_prompt"] as? String { trigger.agentPrompt = v.isEmpty ? nil : v }
                if let v = args["agent_id"] as? String { trigger.agentId = v.isEmpty ? nil : v }
                if let v = args["agent_name"] as? String { trigger.agentName = v.isEmpty ? nil : v }
                if let v = args["agent_deliver"] as? Bool { trigger.agentDeliver = v }
                else if let v = args["agent_deliver"] as? String { trigger.agentDeliver = v == "true" }
                HomeClawConfig.shared.updateWebhookTrigger(trigger)
                result = triggerToDict(trigger)

            case "delete_scene":
                guard let name = args["name"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'name' argument")
                }
                result = try await hk.deleteScene(
                    name: name,
                    homeName: args["home"] as? String,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "assign_rooms":
                guard let assignments = args["assignments"] as? [[String: String]] else {
                    return encodeResponse(success: false, error: "Missing 'assignments' array")
                }
                result = try await hk.assignRooms(
                    homeName: args["home"] as? String,
                    assignments: assignments,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "rename":
                guard let id = args["id"] as? String ?? args["accessory"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'id' or 'accessory' argument")
                }
                guard let newName = args["name"] as? String ?? args["new_name"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'name' or 'new_name' argument")
                }
                result = try await hk.renameAccessory(
                    id: id,
                    newName: newName,
                    homeID: args["home_id"] as? String,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "create_room":
                guard let name = args["name"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'name' argument")
                }
                result = try await hk.createRoom(
                    name: name,
                    homeID: args["home_id"] as? String,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "rename_room":
                guard let roomID = args["id"] as? String ?? args["room"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'id' or 'room' argument")
                }
                guard let newName = args["name"] as? String ?? args["new_name"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'name' or 'new_name' argument")
                }
                result = try await hk.renameRoom(
                    roomID: roomID,
                    newName: newName,
                    homeID: args["home_id"] as? String,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "remove_room":
                guard let roomID = args["id"] as? String ?? args["room"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'id' or 'room' argument")
                }
                result = try await hk.removeRoom(
                    roomID: roomID,
                    homeID: args["home_id"] as? String,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "remove_accessory":
                guard let id = args["id"] as? String ?? args["accessory"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'id' or 'accessory' argument")
                }
                result = try await hk.removeAccessory(
                    id: id,
                    homeID: args["home_id"] as? String,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "create_zone":
                guard let name = args["name"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'name' argument")
                }
                result = try await hk.createZone(
                    name: name,
                    homeID: args["home_id"] as? String,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "remove_zone":
                guard let zoneID = args["id"] as? String ?? args["zone"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'id' or 'zone' argument")
                }
                result = try await hk.removeZone(
                    zoneID: zoneID,
                    homeID: args["home_id"] as? String,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "add_room_to_zone":
                guard let roomID = args["room"] as? String ?? args["room_id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'room' or 'room_id' argument")
                }
                guard let zoneID = args["zone"] as? String ?? args["zone_id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'zone' or 'zone_id' argument")
                }
                result = try await hk.addRoomToZone(
                    roomID: roomID,
                    zoneID: zoneID,
                    homeID: args["home_id"] as? String,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "remove_room_from_zone":
                guard let roomID = args["room"] as? String ?? args["room_id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'room' or 'room_id' argument")
                }
                guard let zoneID = args["zone"] as? String ?? args["zone_id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'zone' or 'zone_id' argument")
                }
                result = try await hk.removeRoomFromZone(
                    roomID: roomID,
                    zoneID: zoneID,
                    homeID: args["home_id"] as? String,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "import_scene":
                guard let name = args["name"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'name' argument")
                }
                guard let actions = args["actions"] as? [[String: String]] else {
                    return encodeResponse(success: false, error: "Missing 'actions' array")
                }
                result = try await hk.importScene(
                    name: name,
                    homeName: args["home"] as? String,
                    actions: actions,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "list_automations":
                result = await hk.listAutomations(homeID: args["home_id"] as? String)

            case "get_automation":
                guard let id = args["id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'id' argument")
                }
                result = try await hk.getAutomation(
                    id: id,
                    homeID: args["home_id"] as? String
                )

            case "create_automation":
                guard let name = args["name"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'name' argument")
                }
                guard let accessoryID = args["accessory_id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'accessory_id' argument")
                }
                guard let sceneID = args["scene_id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'scene_id' argument")
                }
                let pressType = (args["press_type"] as? Int)
                    ?? (args["press_type"] as? String).flatMap(Int.init)
                    ?? 0
                let serviceIndex = (args["service_index"] as? Int)
                    ?? (args["service_index"] as? String).flatMap(Int.init)
                result = try await hk.createAutomation(
                    name: name,
                    accessoryID: accessoryID,
                    pressType: pressType,
                    sceneID: sceneID,
                    serviceIndex: serviceIndex,
                    homeID: args["home_id"] as? String,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "delete_automation":
                guard let id = args["id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'id' argument")
                }
                result = try await hk.deleteAutomation(
                    id: id,
                    homeID: args["home_id"] as? String,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "enable_automation":
                guard let id = args["id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'id' argument")
                }
                let enabled = parseBool(args, key: "enabled", default: true)
                result = try await hk.enableAutomation(
                    id: id,
                    enabled: enabled,
                    homeID: args["home_id"] as? String
                )

            case "webhook_log":
                let limit = (args["limit"] as? Int) ?? (args["limit"] as? String).flatMap(Int.init) ?? 50
                let outcomeFilter: WebhookEventLogger.Outcome? = (args["outcome"] as? String).flatMap {
                    WebhookEventLogger.Outcome(rawValue: $0)
                }
                var since: Date?
                if let sinceStr = args["since"] as? String {
                    since = ISO8601DateFormatter().date(from: sinceStr)
                }
                result = [
                    "entries": WebhookEventLogger.shared.readEntries(
                        since: since, limit: limit, outcome: outcomeFilter),
                ] as [String: Any]

            case "webhook_log_stats":
                result = WebhookEventLogger.shared.logStats()

            case "purge_webhook_log":
                WebhookEventLogger.shared.purge()
                result = WebhookEventLogger.shared.logStats()

            default:
                return encodeResponse(success: false, error: "Unknown command: \(command)")
            }

            return encodeResponse(success: true, data: result)
        } catch {
            return encodeResponse(success: false, error: error.localizedDescription)
        }
    }

    // MARK: - Trigger Serialization

    private func triggerToDict(_ t: HomeClawConfig.WebhookTrigger) -> [String: Any] {
        var dict: [String: Any] = [
            "id": t.id,
            "label": t.label,
            "enabled": t.enabled,
        ]
        if let v = t.accessoryID { dict["accessory_id"] = v }
        if let v = t.accessoryType { dict["accessory_type"] = v }
        if let v = t.sceneName { dict["scene_name"] = v }
        if let v = t.sceneID { dict["scene_id"] = v }
        if let v = t.characteristic { dict["characteristic"] = v }
        if let v = t.value { dict["value"] = v }
        if let v = t.message { dict["message"] = v }
        if let v = t.action { dict["action"] = v }
        if let v = t.wakeMode { dict["wake_mode"] = v }
        if let v = t.agentPrompt { dict["agent_prompt"] = v }
        if let v = t.agentId { dict["agent_id"] = v }
        if let v = t.agentName { dict["agent_name"] = v }
        if let v = t.agentDeliver { dict["agent_deliver"] = v }
        return dict
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

enum SocketError: Error, LocalizedError {
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
