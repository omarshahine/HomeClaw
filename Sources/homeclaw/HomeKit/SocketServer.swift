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

    /// Watchdog: a wedged or torn-down listener (App Nap, an unexpected dispatch
    /// source cancel, an orphaned socket file) leaves the app alive but the socket
    /// refusing connections. A periodic self-connect probe detects this and rebinds.
    private let watchdogQueue = DispatchQueue(label: "com.shahine.homeclaw.socket.watchdog", qos: .utility)
    private var watchdogTimer: DispatchSourceTimer?
    /// Set by `stop()` so the watchdog doesn't fight an intentional shutdown.
    private var intentionallyStopped = false
    private let watchdogInterval: TimeInterval = 30

    /// Reads an integer argument, rejecting values that would otherwise be coerced
    /// into a plausible-but-wrong selector. Returns nil only when the key is absent;
    /// a present-but-malformed value throws so it can never be silently dropped
    /// (dropping a service selector would send the write to a different channel).
    private func parseInt(_ args: [String: Any], key: String) throws -> Int? {
        guard let raw = args[key] else { return nil }
        if let nsNum = raw as? NSNumber {
            // JSON booleans bridge to NSNumber and `as? Int` turns `true` into 1.
            guard CFGetTypeID(nsNum) != CFBooleanGetTypeID() else {
                throw HomeKitManager.ControlError.invalidArgument("\(key) must be an integer, got a boolean")
            }
            guard let int = nsNum as? Int else {
                throw HomeKitManager.ControlError.invalidArgument("\(key) must be a whole number, got \(nsNum)")
            }
            return int
        }
        if let string = raw as? String {
            guard let int = Int(string) else {
                throw HomeKitManager.ControlError.invalidArgument("\(key) must be a whole number, got '\(string)'")
            }
            return int
        }
        throw HomeKitManager.ControlError.invalidArgument("\(key) must be a whole number")
    }

    /// Parse a boolean wire arg, distinguishing absent from present-but-unparseable.
    ///
    /// Accepts:
    ///   - true / false (as JSON booleans, bridged to NSCFBoolean on iOS/macOS)
    ///   - "true" / "false" (case-insensitive strings)
    ///
    /// Rejects (returns `defaultValue`):
    ///   - integers like `1` / `0` (would otherwise silently bool-coerce via `as? Bool`)
    ///   - typo'd strings like `"yes"`, `"1"`, `"on"` (only the literal "true" string is truthy)
    ///
    /// The default-on-unrecognized direction is deliberately the SAFE one for the
    /// most-affected caller (`dry_run`) — typo'd opt-ins become no-ops rather than
    /// silently real-applying. The dangerous direction would be treating an
    /// unparseable input as `true`; this implementation never does that.
    private func parseBool(_ args: [String: Any], key: String, default defaultValue: Bool = false) -> Bool {
        guard let raw = args[key] else { return defaultValue }
        // Accept NSCFBoolean (the runtime class JSON booleans bridge to). Checking
        // CFGetTypeID against CFBooleanGetTypeID rejects NSNumber-bool-coerced
        // integers (`1`, `0`) which would otherwise pass `as? Bool` silently.
        if let nsNum = raw as? NSNumber, CFGetTypeID(nsNum) == CFBooleanGetTypeID() {
            return nsNum.boolValue
        }
        // Accept explicit "true"/"false" strings (case-insensitive). Any other
        // string (e.g. "yes", "1", "on") returns the default — never silently true.
        if let s = raw as? String {
            return s.lowercased() == "true"
        }
        return defaultValue
    }

    /// Thrown by `parseWeekdaysArg` when `weekdays` is present but malformed.
    /// Caller maps the `.message` to `encodeResponse(success: false, error:)`.
    /// Absent → returns `[]` (does not throw), matching the existing default-empty
    /// behavior for the optional `--days` flag.
    fileprivate struct WeekdaysArgError: Error {
        let message: String
    }

    /// Thrown by `parseAccessoryRowsArg` when an `actions` / `conditions` arg is
    /// present but malformed. Caller maps the `.message` to `encodeResponse(success: false, error:)`.
    /// Absent → returns `nil` (does not throw); empty array → returns `[]`.
    fileprivate struct AccessoryRowsArgError: Error {
        let message: String
    }

    /// Strict parser for `actions` / `conditions` socket args (both have the same
    /// `accessory:property:value` row shape, with optional `room`). Mirrors the
    /// `e6ffa1b` `duration_seconds` validation pattern: distinguish absent from
    /// unparseable, reject `__NSCFBoolean` explicitly so JSON `true`/`false` don't
    /// silently coerce, and validate every required field is a non-empty `String`.
    ///
    /// - Parameters:
    ///   - raw: the raw arg value (typically `args["actions"]` or `args["conditions"]`).
    ///   - fieldName: the JSON key name (`"actions"` or `"conditions"`), used in error messages.
    /// - Returns: parsed `[[String: String]]`, or `nil` if the arg is absent. An
    ///   explicit empty array round-trips as `[]` so callers can distinguish absent
    ///   from explicit-empty.
    /// - Throws: `AccessoryRowsArgError` if the arg is present but not an array,
    ///   contains a non-dict element, or contains an element missing/empty/non-string
    ///   `accessory`/`property`/`value` fields, or with non-string field values.
    fileprivate static func parseAccessoryRowsArg(_ raw: Any?, fieldName: String) throws -> [[String: String]]? {
        guard let raw else { return nil }
        guard let array = raw as? [Any] else {
            throw AccessoryRowsArgError(message: "'\(fieldName)' must be an array of {accessory, property, value} dicts")
        }
        var result: [[String: String]] = []
        result.reserveCapacity(array.count)
        for (index, element) in array.enumerated() {
            guard let dict = element as? [String: Any] else {
                throw AccessoryRowsArgError(message: "'\(fieldName)'[\(index)] must be a dict with string 'accessory', 'property', 'value' fields")
            }
            var row: [String: String] = [:]
            for key in ["accessory", "property", "value"] {
                guard let raw = dict[key] else {
                    throw AccessoryRowsArgError(message: "'\(fieldName)'[\(index)] missing required string field '\(key)'")
                }
                // Reject NSNumber-bools and NSNumbers: JSON booleans bridge as
                // __NSCFBoolean and would silently cast in surprising ways.
                if let nsNum = raw as? NSNumber, CFGetTypeID(nsNum) == CFBooleanGetTypeID() {
                    throw AccessoryRowsArgError(message: "'\(fieldName)'[\(index)].\(key) is a boolean; expected a non-empty string")
                }
                guard let strVal = raw as? String else {
                    throw AccessoryRowsArgError(message: "'\(fieldName)'[\(index)].\(key) must be a string")
                }
                guard !strVal.isEmpty else {
                    throw AccessoryRowsArgError(message: "'\(fieldName)'[\(index)].\(key) must be a non-empty string")
                }
                row[key] = strVal
            }
            // Optional `room` field — trim and reject whitespace-only at intake.
            // A bare `.isEmpty` check would accept `"   "` and let it propagate to
            // the resolver, where the trim-to-nil pattern would silently drop the
            // explicit-but-malformed scope and widen the accessory lookup to all
            // rooms — potentially binding the condition to the wrong same-named
            // accessory. Matches the discipline applied to the required
            // accessory/property/value fields and to the add-condition socket
            // handler's `room` validation.
            if let roomRaw = dict["room"] {
                guard let roomStr = roomRaw as? String else {
                    throw AccessoryRowsArgError(message: "'\(fieldName)'[\(index)].room must be a non-empty string when provided")
                }
                let trimmed = roomStr.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    throw AccessoryRowsArgError(message: "'\(fieldName)'[\(index)].room must be a non-empty string when provided")
                }
                row["room"] = trimmed
            }
            result.append(row)
        }
        return result
    }

    /// Strict parser for the `weekdays` socket arg. Mirrors the `e6ffa1b`
    /// `duration_seconds` validation pattern: distinguish absent from unparseable, reject
    /// `__NSCFBoolean` explicitly so JSON `true`/`false` don't coerce to `1`/`0`,
    /// and validate each element is an `Int` (or `String` parseable to `Int`)
    /// in the HomeKit weekday range `1...7` (1=Sunday, 7=Saturday).
    ///
    /// - Returns: parsed `[Int]` (empty if the arg is absent).
    /// - Throws: `WeekdaysArgError` if the arg is present but not an array,
    ///   contains a non-Int / non-Int-parseable-String element, contains an
    ///   `NSNumber`-bool, or contains an element outside `1...7`.
    fileprivate static func parseWeekdaysArg(_ raw: Any?) throws -> [Int] {
        guard let raw else { return [] }
        guard let array = raw as? [Any] else {
            throw WeekdaysArgError(message: "'weekdays' must be an array of integers in 1...7 (1=Sunday, 7=Saturday)")
        }
        var result: [Int] = []
        result.reserveCapacity(array.count)
        for element in array {
            // Reject JSON booleans (bridged as __NSCFBoolean, which casts to Int 0/1).
            if let nsNum = element as? NSNumber, CFGetTypeID(nsNum) == CFBooleanGetTypeID() {
                throw WeekdaysArgError(message: "'weekdays' contains a boolean; expected integers in 1...7")
            }
            let parsed: Int?
            if let intVal = element as? Int {
                parsed = intVal
            } else if let strVal = element as? String, let intFromStr = Int(strVal) {
                parsed = intFromStr
            } else {
                parsed = nil
            }
            guard let day = parsed else {
                throw WeekdaysArgError(message: "'weekdays' contains a non-integer value; expected integers in 1...7")
            }
            guard (1...7).contains(day) else {
                throw WeekdaysArgError(message: "'weekdays' value \(day) is out of range; expected integers in 1...7 (1=Sunday, 7=Saturday)")
            }
            result.append(day)
        }
        return result
    }

    /// Thrown by `parseStringArrayArg` when a `time_after` / `time_before` arg is
    /// present but malformed. Caller maps the `.message` to `encodeResponse(success: false, error:)`.
    /// Absent → returns `[]` (does not throw), matching the existing default-empty
    /// behavior for the optional time-predicate flags.
    fileprivate struct StringArrayArgError: Error {
        let message: String
    }

    /// Strict parser for the `time_after` / `time_before` socket args. Mirrors the
    /// `e6ffa1b` pattern: distinguish absent (returns `[]`) from present-but-malformed
    /// (throws) so a misshapen value returns a precise error instead of silently
    /// dropping the predicate and creating an automation without the requested gate.
    ///
    /// - Parameters:
    ///   - raw: the raw arg value (typically `args["time_after"]` or `args["time_before"]`).
    ///   - fieldName: the JSON key name, used in error messages.
    /// - Returns: parsed `[String]`, or `[]` if the arg is absent.
    /// - Throws: `StringArrayArgError` if the arg is present but not an array of strings.
    fileprivate static func parseStringArrayArg(_ raw: Any?, fieldName: String) throws -> [String] {
        guard let raw else { return [] }
        guard let array = raw as? [Any] else {
            throw StringArrayArgError(message: "'\(fieldName)' must be an array of strings (e.g. 'sunset-30', 'sunrise+15').")
        }
        var result: [String] = []
        result.reserveCapacity(array.count)
        for (index, element) in array.enumerated() {
            // Reject JSON booleans explicitly (bridged as __NSCFBoolean which would
            // otherwise cast to neither String nor a useful type).
            if let nsNum = element as? NSNumber, CFGetTypeID(nsNum) == CFBooleanGetTypeID() {
                throw StringArrayArgError(message: "'\(fieldName)'[\(index)] is a boolean; expected a non-empty string")
            }
            guard let strVal = element as? String else {
                throw StringArrayArgError(message: "'\(fieldName)'[\(index)] must be a string")
            }
            guard !strVal.isEmpty else {
                throw StringArrayArgError(message: "'\(fieldName)'[\(index)] must be a non-empty string")
            }
            result.append(strVal)
        }
        return result
    }

    /// Start the socket server synchronously (non-blocking — sets up GCD dispatch sources)
    /// and arm the watchdog that keeps it alive.
    func start() {
        intentionallyStopped = false
        bringUpListener()
        startWatchdog()
    }

    /// Bind, listen, and arm the accept dispatch source. Idempotent: unlinks any
    /// stale socket file first, so it is safe to call repeatedly (e.g. from the
    /// watchdog after a wedge).
    private func bringUpListener() {
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
            serverFD = -1
            return
        }

        // Listen
        guard listen(serverFD, 16) == 0 else {
            AppLogger.socket.error("Failed to listen on socket (errno: \(errno))")
            close(serverFD)
            serverFD = -1
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
        // Close the listening fd on cancel. We deliberately do NOT unlink the path
        // here: `bringUpListener` already unlinks-before-bind, so unlinking on cancel
        // would race a concurrent restart and delete the freshly-bound socket file.
        let cancelFD = serverFD
        source.setCancelHandler {
            if cancelFD >= 0 { close(cancelFD) }
        }
        source.resume()
        acceptSource = source

        AppLogger.socket.info("Socket server listening at \(path)")
    }

    func stop() {
        intentionallyStopped = true
        watchdogTimer?.cancel()
        watchdogTimer = nil
        acceptSource?.cancel()
        acceptSource = nil
        serverFD = -1
        unlink(AppConfig.socketPath)
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
        timer.setEventHandler { [weak self] in self?.checkListenerHealth() }
        timer.resume()
        watchdogTimer = timer
    }

    /// Probe the socket with a real connect(). A live listener accepts it (and our
    /// empty request is discarded cleanly); a wedged/absent listener fails, which
    /// triggers a rebind. Runs on the watchdog queue, independent of the accept queue.
    private func checkListenerHealth() {
        guard !intentionallyStopped else { return }
        guard !canConnectToSocket() else { return }
        AppLogger.socket.error("Socket listener unhealthy (connect failed) — rebinding")
        queue.async { [weak self] in
            guard let self, !self.intentionallyStopped else { return }
            self.acceptSource?.cancel()
            self.acceptSource = nil
            self.serverFD = -1
            self.bringUpListener()
        }
    }

    private func canConnectToSocket() -> Bool {
        let path = AppConfig.socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = memcpy(ptr, cstr, min(path.utf8.count, MemoryLayout.size(ofValue: ptr.pointee) - 1))
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
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
                // `refresh: false` skips live characteristic reads — instant, and
                // all that's needed for serial-number / model / firmware sweeps.
                // Defaults to true to preserve prior behavior.
                let refresh = parseBool(args, key: "refresh", default: true)
                guard let accessory = await hk.getAccessory(id: id, homeID: args["home_id"] as? String, refresh: refresh) else {
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
                    serviceName: args["service_name"] as? String,
                    serviceID: args["service_id"] as? String,
                    serviceIndex: try parseInt(args, key: "service_index"),
                    dryRun: parseBool(args, key: "dry_run"),
                    verify: parseBool(args, key: "verify", default: true)
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
                // 'name' accepts a scene name or UUID; 'id' is an alias so scene
                // commands key uniformly on either identifier (issue #76).
                guard let name = args["name"] as? String ?? args["id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'name' or 'id' argument")
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

            case "update_scene":
                guard let nameOrID = (args["id"] as? String) ?? (args["name"] as? String) else {
                    return encodeResponse(success: false, error: "Missing 'name' or 'id' argument")
                }
                guard let actions = args["actions"] as? [[String: String]] else {
                    return encodeResponse(success: false, error: "Missing 'actions' array")
                }
                result = try await hk.updateScene(
                    nameOrID: nameOrID,
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
                guard let name = args["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return encodeResponse(success: false, error: "Missing or empty 'name' argument")
                }
                guard let accessoryID = args["accessory_id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'accessory_id' argument")
                }
                let sceneID = args["scene_id"] as? String
                // Strict parse: distinguish absent (nil) from present-but-malformed
                // (throws) so a misshapen `actions` arg returns a precise error
                // instead of silently coercing to nil and surfacing the misleading
                // "Either 'scene_id' or 'actions' array is required".
                let actions: [[String: String]]?
                do {
                    actions = try Self.parseAccessoryRowsArg(args["actions"], fieldName: "actions")
                } catch let err as AccessoryRowsArgError {
                    return encodeResponse(success: false, error: err.message)
                }
                guard sceneID != nil || (actions != nil && !actions!.isEmpty) else {
                    return encodeResponse(success: false, error: "Either 'scene_id' or 'actions' array is required")
                }
                let characteristic = args["characteristic"] as? String
                let triggerValue = args["trigger_value"] as? String
                let pressType = (args["press_type"] as? Int)
                    ?? (args["press_type"] as? String).flatMap(Int.init)
                    ?? 0
                let serviceIndex = (args["service_index"] as? Int)
                    ?? (args["service_index"] as? String).flatMap(Int.init)
                let weekdays: [Int]
                do {
                    weekdays = try Self.parseWeekdaysArg(args["weekdays"])
                } catch let err as WeekdaysArgError {
                    return encodeResponse(success: false, error: err.message)
                }
                let conditions: [[String: String]]
                do {
                    conditions = try Self.parseAccessoryRowsArg(args["conditions"], fieldName: "conditions") ?? []
                } catch let err as AccessoryRowsArgError {
                    return encodeResponse(success: false, error: err.message)
                }
                // Parse time predicates (clock times and sun-relative events). The CLI/MCP
                // layer pre-validates format, but defensively re-validate here so direct
                // socket clients can't bypass it.
                let timeAfterRaw: [String]
                let timeBeforeRaw: [String]
                do {
                    timeAfterRaw = try Self.parseStringArrayArg(args["time_after"], fieldName: "time_after")
                    timeBeforeRaw = try Self.parseStringArrayArg(args["time_before"], fieldName: "time_before")
                } catch let err as StringArrayArgError {
                    return encodeResponse(success: false, error: err.message)
                }
                var timeConditions: [TimeCondition] = []
                for raw in timeAfterRaw {
                    guard let tc = TimeCondition.parse(raw, relation: .after) else {
                        return encodeResponse(success: false,
                            error: "Invalid 'time_after' value '\(raw)'. Use a clock time 'HH:MM' (zero-padded, e.g. '07:00') or sunrise/sunset with optional ±N minutes (e.g. 'sunset-30').")
                    }
                    timeConditions.append(tc)
                }
                for raw in timeBeforeRaw {
                    guard let tc = TimeCondition.parse(raw, relation: .before) else {
                        return encodeResponse(success: false,
                            error: "Invalid 'time_before' value '\(raw)'. Use a clock time 'HH:MM' (zero-padded, e.g. '20:30') or sunrise/sunset with optional ±N minutes (e.g. 'sunrise+15').")
                    }
                    timeConditions.append(tc)
                }
                // Distinguish "missing" from "present but invalid" so unparseable values
                // (e.g. "300s", 300.5, true) return a validation error instead of silently
                // creating an automation without auto-off.
                let durationSeconds: Int?
                if let raw = args["duration_seconds"] {
                    // JSONSerialization bridges JSON booleans as __NSCFBoolean which casts
                    // to Int(0/1); reject explicitly so `true` doesn't become a 1s auto-off.
                    let isBool: Bool = {
                        guard let nsNum = raw as? NSNumber else { return false }
                        return CFGetTypeID(nsNum) == CFBooleanGetTypeID()
                    }()
                    let parsed: Int? = isBool
                        ? nil
                        : ((raw as? Int) ?? (raw as? String).flatMap(Int.init))
                    guard let parsed, (1...86400).contains(parsed) else {
                        return encodeResponse(
                            success: false,
                            error: "'duration_seconds' must be a positive integer between 1 and 86400 (24 hours)"
                        )
                    }
                    durationSeconds = parsed
                } else {
                    durationSeconds = nil
                }
                result = try await hk.createAutomation(
                    name: name,
                    accessoryID: accessoryID,
                    pressType: pressType,
                    characteristic: characteristic,
                    triggerValue: triggerValue,
                    sceneID: sceneID,
                    actions: actions,
                    serviceIndex: serviceIndex,
                    weekdays: weekdays,
                    conditions: conditions,
                    timeConditions: timeConditions,
                    durationSeconds: durationSeconds,
                    homeID: args["home_id"] as? String,
                    dryRun: parseBool(args, key: "dry_run")
                )

            case "create_time_automation":
                guard let name = args["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return encodeResponse(success: false, error: "Missing or empty 'name' argument")
                }
                guard let time = args["time"] as? String, !time.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return encodeResponse(success: false,
                        error: "Missing or empty 'time' argument. Use 'HH:MM' (e.g. '06:30'), 'sunrise', 'sunset', or '<sun-event>±<minutes>' (e.g. 'sunset-30').")
                }
                // Defense-in-depth: re-validate format here so direct-socket clients
                // can't bypass the CLI's `validateTimeOfDaySpec` pre-check. The
                // manager re-runs `TimeSpec.parse` at HomeKit-mutation time (it's the
                // canonical source of truth); this layer just shortens the round-trip
                // for bad input. Errors surface the underlying `ParseError.message`
                // text the manager would have returned, prefixed with `Invalid 'time'
                // argument:` so socket clients know which arg failed.
                do {
                    _ = try TimeSpec.parse(time)
                } catch let err as TimeSpec.ParseError {
                    return encodeResponse(success: false, error: "Invalid 'time' argument: \(err.message)")
                }
                let sceneID = args["scene_id"] as? String
                // Strict parse: see `create_automation` for the rationale (distinguish
                // absent from present-but-malformed so the "Either 'scene_id' or 'actions'…"
                // error is reserved for the genuinely-missing case).
                let actions: [[String: String]]?
                do {
                    actions = try Self.parseAccessoryRowsArg(args["actions"], fieldName: "actions")
                } catch let err as AccessoryRowsArgError {
                    return encodeResponse(success: false, error: err.message)
                }
                guard sceneID != nil || (actions != nil && !actions!.isEmpty) else {
                    return encodeResponse(success: false, error: "Either 'scene_id' or 'actions' array is required")
                }
                let weekdays: [Int]
                do {
                    weekdays = try Self.parseWeekdaysArg(args["weekdays"])
                } catch let err as WeekdaysArgError {
                    return encodeResponse(success: false, error: err.message)
                }
                let conditions: [[String: String]]
                do {
                    conditions = try Self.parseAccessoryRowsArg(args["conditions"], fieldName: "conditions") ?? []
                } catch let err as AccessoryRowsArgError {
                    return encodeResponse(success: false, error: err.message)
                }
                let timeAfterRaw: [String]
                let timeBeforeRaw: [String]
                do {
                    timeAfterRaw = try Self.parseStringArrayArg(args["time_after"], fieldName: "time_after")
                    timeBeforeRaw = try Self.parseStringArrayArg(args["time_before"], fieldName: "time_before")
                } catch let err as StringArrayArgError {
                    return encodeResponse(success: false, error: err.message)
                }
                var timeConditions: [TimeCondition] = []
                for raw in timeAfterRaw {
                    guard let tc = TimeCondition.parse(raw, relation: .after) else {
                        return encodeResponse(success: false,
                            error: "Invalid 'time_after' value '\(raw)'. Use a clock time 'HH:MM' (zero-padded, e.g. '07:00') or sunrise/sunset with optional ±N minutes (e.g. 'sunset-30').")
                    }
                    timeConditions.append(tc)
                }
                for raw in timeBeforeRaw {
                    guard let tc = TimeCondition.parse(raw, relation: .before) else {
                        return encodeResponse(success: false,
                            error: "Invalid 'time_before' value '\(raw)'. Use a clock time 'HH:MM' (zero-padded, e.g. '20:30') or sunrise/sunset with optional ±N minutes (e.g. 'sunrise+15').")
                    }
                    timeConditions.append(tc)
                }
                // Mirror the e6ffa1b validation pattern: distinguish absent from unparseable,
                // and reject NSNumber-bool (`true`/`false` in JSON would otherwise become 1/0).
                let durationSeconds: Int?
                if let raw = args["duration_seconds"] {
                    let isBool: Bool = {
                        guard let nsNum = raw as? NSNumber else { return false }
                        return CFGetTypeID(nsNum) == CFBooleanGetTypeID()
                    }()
                    let parsed: Int? = isBool
                        ? nil
                        : ((raw as? Int) ?? (raw as? String).flatMap(Int.init))
                    guard let parsed, (1...86400).contains(parsed) else {
                        return encodeResponse(
                            success: false,
                            error: "'duration_seconds' must be a positive integer between 1 and 86400 (24 hours)"
                        )
                    }
                    durationSeconds = parsed
                } else {
                    durationSeconds = nil
                }
                result = try await hk.createTimeAutomation(
                    name: name,
                    time: time,
                    weekdays: weekdays,
                    conditions: conditions,
                    timeConditions: timeConditions,
                    durationSeconds: durationSeconds,
                    sceneID: sceneID,
                    actions: actions,
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

            case "update_automation":
                guard let id = args["id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'id' argument")
                }
                let addList = (args["add_scenes"] as? [String]) ?? []
                let removeList = (args["remove_scenes"] as? [String]) ?? []
                if addList.isEmpty && removeList.isEmpty {
                    return encodeResponse(success: false, error: "Provide at least one of 'add_scenes' or 'remove_scenes'")
                }
                result = try await hk.updateAutomationActionSets(
                    id: id,
                    addSceneIDs: addList,
                    removeSceneIDs: removeList,
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

            case "add_automation_condition":
                // Wire contract: flat args (`accessory`, `property`, `value`, `room`) — the
                // MCP/JS handler unpacks the nested `condition` object into these flat
                // siblings. Direct socket clients bypassing the JS layer should send the
                // flat shape, not the nested.
                //
                // Required string args: id, accessory, property, value. Validate each
                // is present AND non-empty (after whitespace trim) so a whitespace-only
                // string from the wire can't slip through to HomeKitManager. Mirrors the
                // CLI `validate()` rules and the discipline established by the
                // duration_seconds parsing above — distinguish absent from unparseable.
                // Trim once and forward the trimmed values. Validating a trimmed
                // string but forwarding the raw form (the prior bug) meant
                // `--accessory " Front Door "` validated fine but the manager-side
                // lookup got the padded form and threw `accessoryNotFound`.
                guard let idRaw = args["id"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'id' argument")
                }
                let id = idRaw.trimmingCharacters(in: .whitespaces)
                guard !id.isEmpty else {
                    return encodeResponse(success: false, error: "'id' argument must be non-empty (after trimming whitespace)")
                }
                guard let accessoryRaw = args["accessory"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'accessory' argument")
                }
                let accessory = accessoryRaw.trimmingCharacters(in: .whitespaces)
                guard !accessory.isEmpty else {
                    return encodeResponse(success: false, error: "'accessory' argument must be non-empty (after trimming whitespace)")
                }
                guard let propertyRaw = args["property"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'property' argument")
                }
                let property = propertyRaw.trimmingCharacters(in: .whitespaces)
                guard !property.isEmpty else {
                    return encodeResponse(success: false, error: "'property' argument must be non-empty (after trimming whitespace)")
                }
                guard let valueRaw = args["value"] as? String else {
                    return encodeResponse(success: false, error: "Missing 'value' argument")
                }
                let value = valueRaw.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else {
                    return encodeResponse(success: false, error: "'value' argument must be non-empty (after trimming whitespace)")
                }
                // Optional room disambiguator — mirrors the `condition.room` field
                // accepted by `create`/`create-time`. Forwarded to HomeKitManager so
                // accessory name lookup can scope by room when multiple accessories
                // share a name across rooms. Distinguish absent (nil OK) from
                // present-but-malformed (e.g. `room: 123` or `room: ["Kitchen"]`),
                // mirroring the e6ffa1b validation pattern Omar applied to
                // time_after / time_before in a46ac9f. Empty / whitespace-only
                // strings are rejected up-front rather than silently coerced to nil.
                let conditionRoom: String?
                if let raw = args["room"] {
                    guard let s = raw as? String else {
                        return encodeResponse(success: false, error: "'room' must be a string when provided")
                    }
                    let trimmed = s.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        return encodeResponse(success: false, error: "'room' must be non-empty when provided")
                    }
                    conditionRoom = trimmed
                } else {
                    conditionRoom = nil
                }
                result = try await hk.addAutomationCondition(
                    id: id,
                    accessoryID: accessory,
                    conditionRoom: conditionRoom,
                    property: property,
                    value: value,
                    homeID: args["home_id"] as? String,
                    dryRun: parseBool(args, key: "dry_run")
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
