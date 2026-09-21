import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

struct HTTPRequest: Sendable {
    let method: String
    let uri: String
    let headers: [String: String]
    let body: Data?
    init(method: String, uri: String = "/mcp", headers: [String: String] = [:], body: Data? = nil) {
        self.method = method; self.uri = uri; self.body = body
        var merged: [String: String] = [:]
        for (name, value) in headers {
            if let existing = merged.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }) {
                merged[existing.key] = "\(existing.value), \(value)"
            } else { merged[name] = value }
        }
        self.headers = merged
    }
    func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
}

struct MCPConnectionLimitError: Error {}

struct SSEStreamOwnership: Sendable, Hashable { let sessionID: String; let token: UUID }

struct HTTPResponse: Sendable, Equatable {
    let statusCode: Int; let headers: [String: String]; let bodyData: Data?
    let stream: AsyncStream<Data>?; let sseOwnership: SSEStreamOwnership?
    init(statusCode: Int, headers: [String: String] = [:], bodyData: Data? = nil, stream: AsyncStream<Data>? = nil, sseOwnership: SSEStreamOwnership? = nil) {
        self.statusCode = statusCode; self.headers = headers; self.bodyData = bodyData; self.stream = stream; self.sseOwnership = sseOwnership
    }
    func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
    var bodyString: String? { bodyData.flatMap { String(data: $0, encoding: .utf8) } }
    static func == (lhs: HTTPResponse, rhs: HTTPResponse) -> Bool { lhs.statusCode == rhs.statusCode && lhs.headers == rhs.headers && lhs.bodyData == rhs.bodyData }
    static func error(statusCode: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, headers: ["Content-Type": "application/json; charset=utf-8"], bodyData: MCPServer.jsonRPCErrorData(code: -32600, message: message))
    }
}

actor MCPServer {
    /// Protocol revisions this server implements, newest first.
    ///
    /// 2025-11-25 differs from 2025-06-18 on this transport only in MUSTs we
    /// meet (403 for a bad Origin); its other changes are optional features.
    /// 2025-03-26 is deliberately absent: it requires accepting JSON-RPC
    /// batches, which this server rejects. Such clients are offered the latest.
    static let supportedProtocolVersions = ["2025-11-25", "2025-06-18"]
    static let latestProtocolVersion = supportedProtocolVersions[0]

    /// Version negotiation: echo a supported request, else offer our latest.
    static func negotiatedProtocolVersion(for requested: String) -> String {
        supportedProtocolVersions.contains(requested) ? requested : latestProtocolVersion
    }
    private let configuration: HTTPMCPConfiguration
    private var group: MultiThreadedEventLoopGroup?; private var channel: Channel?
    private var listenerReady = false; private var homeKitReady: Bool
    private let toolRegistry: MCPToolRegistry
    private var sseContinuations: [String: (ownership: SSEStreamOwnership, continuation: AsyncStream<Data>.Continuation)] = [:]
    private var expiryTask: Task<Void, Never>?
    private let dispatchTimeout: Duration
    let sessionStore: StreamableHTTPSessionStore
    private var lifecycleGeneration: UInt64 = 0
    private var isStarting = false
    private let toolPolicy: HTTPToolPolicy
    private let toolAdmission: ToolDispatchAdmission
    private var connectionTracker: MCPHTTPConnectionTracker?

    init(configuration: HTTPMCPConfiguration = .init(port: AppConfig.mcpPort, bindHost: AppConfig.mcpBindHost), homeKitReady: Bool = false, sessionStore: StreamableHTTPSessionStore? = nil, toolRegistry: MCPToolRegistry = HomeClawMCPToolRegistry.shared, toolPolicy: HTTPToolPolicy = .readOnly, dispatchTimeout: Duration = .seconds(120)) {
        self.configuration = configuration; self.homeKitReady = homeKitReady; self.toolRegistry = toolRegistry; self.toolPolicy = toolPolicy; self.dispatchTimeout = dispatchTimeout
        self.sessionStore = sessionStore ?? .init(ttl: configuration.sessionTTL, maxSessions: configuration.maxSessions)
        self.toolAdmission = ToolDispatchAdmission(limit: configuration.maxConcurrentToolCalls)
    }
    var endpoint: String { AppConfig.mcpEndpoint }; var bindHost: String { configuration.bindHost }
    private var homeKitReadySequence: UInt64 = 0
    /// Applies a readiness change. `sequence` (when given) must increase; an
    /// older update that arrives late is ignored.
    func updateHomeKitReady(_ ready: Bool, sequence: UInt64? = nil) {
        if let sequence { guard sequence > homeKitReadySequence else { return }; homeKitReadySequence = sequence }
        homeKitReady = ready; NotificationCenter.default.post(name: .mcpListenerStatusDidChange, object: nil, userInfo: ["listenerReady": listenerReady, "homeKitReady": ready])
    }

    func start() async throws {
        guard channel == nil, !isStarting else { return }; try configuration.validateLoopbackBind()
        isStarting = true; defer { isStarting = false }
        let generation = lifecycleGeneration
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let tracker = MCPHTTPConnectionTracker(maxConnections: configuration.maxConnections)
        let idleTimeout = configuration.idleTimeout
        let maxInflight = configuration.maxInflightPerChannel
        do {
            let channel = try await ServerBootstrap(group: group).serverChannelOption(.backlog, value: 256).serverChannelOption(.socketOption(.so_reuseaddr), value: 1).childChannelInitializer { channel in
                // Over the connection cap (or shutting down): a failed initializer
                // makes ServerBootstrap close the accepted socket.
                guard tracker.admit(channel) else { return channel.eventLoop.makeFailedFuture(MCPConnectionLimitError()) }
                return channel.pipeline.addHandler(IdleStateHandler(readTimeout: idleTimeout))
                    .flatMap { channel.pipeline.configureHTTPServerPipeline() }
                    .flatMap { channel.pipeline.addHandler(MCPHTTPHandler(server: self, tracker: tracker, maxInflight: maxInflight)) }
            }.bind(host: configuration.bindHost, port: configuration.port).get()
            guard generation == lifecycleGeneration else {
                try? await channel.close()
                await tracker.shutdown()
                try? await group.shutdownGracefully()
                return
            }
            self.group = group; self.channel = channel; self.connectionTracker = tracker; listenerReady = true; startExpiryCleanup()
            NotificationCenter.default.post(name: .mcpListenerStatusDidChange, object: nil, userInfo: ["listenerReady": true, "homeKitReady": homeKitReady])
        } catch { try? await group.shutdownGracefully(); throw error }
    }
    func stop() async {
        lifecycleGeneration &+= 1
        let channel = self.channel; let group = self.group; let tracker = connectionTracker
        self.channel = nil; self.group = nil; connectionTracker = nil; listenerReady = false
        expiryTask?.cancel(); expiryTask = nil; _ = await sessionStore.removeAll(); cleanupSSE(for: Array(sseContinuations.keys))
        NotificationCenter.default.post(name: .mcpListenerStatusDidChange, object: nil, userInfo: ["listenerReady": false, "homeKitReady": homeKitReady])
        if let channel { try? await channel.close() }
        // Drain before shutting the loop down: in-flight request tasks hop back
        // onto the event loop when they finish, and scheduling on a shut-down
        // loop is an error (a crash in strict mode). Bounded so a wedged task
        // cannot hang Quit.
        if let tracker {
            _ = await DispatchTimeoutRace.run(timeout: .seconds(5), timeoutValue: false) { await tracker.shutdown(); return true }
        }
        if let group { try? await group.shutdownGracefully() }
    }
    #if DEBUG
    /// Read-only ownership snapshot for channel lifecycle regressions.
    var testSSEOwnerships: Set<SSEStreamOwnership> { Set(sseContinuations.values.map(\.ownership)) }
    #endif

    func cleanupSSE(for sessionIDs: [String]) { sessionIDs.forEach { sseContinuations.removeValue(forKey: $0)?.continuation.finish() } }
    func cleanupSSE(for ownership: SSEStreamOwnership) { guard sseContinuations[ownership.sessionID]?.ownership == ownership else { return }; sseContinuations.removeValue(forKey: ownership.sessionID)?.continuation.finish() }
    func cleanupSSE(for sessionID: String) { cleanupSSE(for: [sessionID]) }
    func cleanupExpiredSessions(now: Date = Date()) async { cleanupSSE(for: await sessionStore.removeExpiredIDs(now: now)) }
    func startExpiryCleanup() { guard expiryTask == nil else { return }; let interval = max(1, min(configuration.sessionTTL / 2, 60)); expiryTask = Task { [weak self] in while !Task.isCancelled { do { try await Task.sleep(for: .seconds(interval)) } catch { return }; guard let self, !Task.isCancelled else { return }; await self.cleanupExpiredSessions() } } }

    func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        await cleanupExpiredSessions(); let path = request.uri.split(separator: "?").first.map(String.init) ?? request.uri
        if path == "/healthz" { let h = HTTPMCPHealthResponse(listenerReady: listenerReady, homeKitReady: homeKitReady); return HTTPResponse(statusCode: h.statusCode, headers: ["Content-Type": "application/json; charset=utf-8"], bodyData: h.bodyData) }
        guard path == URL(string: endpoint)?.path || path == endpoint else { return protocolError(status: 404, code: -32600, message: "Not Found") }
        let method = request.method.uppercased(); guard ["POST", "GET", "DELETE"].contains(method) else { return protocolError(status: 405, code: -32600, message: "Method Not Allowed", headers: ["Allow": "GET, POST, DELETE"]) }
        let acceptableResponse = switch method {
        case "POST": acceptsJSON(request.header("Accept"))
        case "GET": acceptsEventStream(request.header("Accept"))
        default: accepts(request.header("Accept"))
        }
        guard acceptableResponse else { return protocolError(status: 406, code: -32600, message: "Accept must include application/json for POST or text/event-stream for GET") }
        if method == "POST" { return await handlePOST(request) }
        guard let id = request.header("Mcp-Session-Id") else { return protocolError(status: 400, code: -32600, message: "Missing Mcp-Session-Id header") }
        guard let session = await sessionStore.validateAndTouch(id) else { return protocolError(status: 404, code: -32600, message: "Session not found or expired") }
        if let versionError = protocolVersionError(request, session: session) { return versionError }
        // Remove from the store before finishing the stream. A concurrent GET
        // re-checks the store after registering (below), so either it sees the
        // session gone and retires its own stream, or this cleanup runs after
        // its registration and retires it.
        if method == "DELETE" { _ = await sessionStore.remove(id); cleanupSSE(for: id); return HTTPResponse(statusCode: 200) }
        var continuation: AsyncStream<Data>.Continuation!; let stream = AsyncStream<Data> { continuation = $0 }; continuation.yield(Data(": connected\n\n".utf8)); let ownership = SSEStreamOwnership(sessionID: id, token: UUID())
        sseContinuations.removeValue(forKey: id)?.continuation.finish(); sseContinuations[id] = (ownership, continuation)
        // The session may have been deleted, expired or evicted while this GET
        // was suspended after validation. Every removal path removes from the
        // store before cleaning streams, so re-checking here closes the gap.
        guard await sessionStore.get(id) != nil else {
            cleanupSSE(for: ownership)
            return protocolError(status: 404, code: -32600, message: "Session not found or expired")
        }
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"], stream: stream, sseOwnership: ownership)
    }

    private func handlePOST(_ request: HTTPRequest) async -> HTTPResponse {
        guard contentTypeIsJSON(request.header("Content-Type")) else { return protocolError(status: 415, code: -32600, message: "Content-Type must be application/json") }
        guard let body = request.body, let object = try? JSONSerialization.jsonObject(with: body), let json = object as? [String: Any], isJSONRPC(json) else { return protocolError(status: 400, code: -32600, message: "Invalid JSON-RPC request") }
        let method = json["method"] as? String; let initialize = method == "initialize"; let supplied = request.header("Mcp-Session-Id")
        if initialize && supplied != nil { return protocolError(status: 400, code: -32600, message: "Initialize must not include Mcp-Session-Id") }
        // Notifications (no "id") never create sessions; they are not addressable — check before validation
        let isNotification = !json.keys.contains("id")
        if isNotification, initialize { return HTTPResponse(statusCode: 202) }
        // Validate initialize params before allocating any session state (only for non-notification initialize)
        if initialize, let paramsError = validateInitializeParams(json) { return paramsError }
        if initialize {
        } else {
            guard let supplied else { return protocolError(status: 400, code: -32600, message: "Missing Mcp-Session-Id header") }
            guard let session = await sessionStore.validateAndTouch(supplied) else { return protocolError(status: 404, code: -32600, message: "Session not found or expired") }
            if let versionError = protocolVersionError(request, session: session) { return versionError }
            if isNotification { return HTTPResponse(statusCode: 202) }
        }
        let id: String
        if let supplied {
            id = supplied
        } else {
            let requested = (json["params"] as? [String: Any])?["protocolVersion"] as? String ?? Self.latestProtocolVersion
            // A full store evicts its least-recently-used session (sparing live
            // SSE streams when it can) rather than locking new clients out.
            guard let created = await sessionStore.create(protocolVersion: Self.negotiatedProtocolVersion(for: requested), protected: Set(sseContinuations.keys)) else {
                return protocolError(status: 503, code: -32600, message: "Sessions unavailable")
            }
            if let evicted = created.evicted { cleanupSSE(for: evicted) }
            id = created.id
        }
        guard !isNotification else { return HTTPResponse(statusCode: 202) }
        var headers = ["Content-Type": "application/json; charset=utf-8"]; if supplied == nil { headers["Mcp-Session-Id"] = id }
        return HTTPResponse(statusCode: 200, headers: headers, bodyData: await rpcResponse(for: json))
    }

    private func validateInitializeParams(_ json: [String: Any]) -> HTTPResponse? {
        guard let params = json["params"] as? [String: Any] else {
            return protocolError(status: 400, code: -32602, message: "Missing initialize params")
        }
        // Any string is acceptable: an unsupported version is answered with the
        // server's latest, and the client decides whether it can proceed.
        guard let pv = params["protocolVersion"] as? String, !pv.isEmpty else {
            return protocolError(status: 400, code: -32602, message: "Invalid or missing protocolVersion")
        }
        guard params["capabilities"] is [String: Any] else {
            return protocolError(status: 400, code: -32602, message: "Missing capabilities")
        }
        guard let ci = params["clientInfo"] as? [String: Any], ci["name"] is String, ci["version"] is String else {
            return protocolError(status: 400, code: -32602, message: "Missing clientInfo")
        }
        return nil
    }

    private func rpcResponse(for json: [String: Any]) async -> Data {
        let id = json["id"] ?? NSNull(); guard let method = json["method"] as? String else { return Self.jsonRPCErrorData(id: id, code: -32600, message: "Invalid Request") }
        if method == "initialize" {
            let requested = (json["params"] as? [String: Any])?["protocolVersion"] as? String ?? Self.latestProtocolVersion
            return jsonData(["jsonrpc":"2.0", "id":id, "result":["protocolVersion":Self.negotiatedProtocolVersion(for: requested), "capabilities":["tools":["listChanged":false]], "serverInfo":["name":"HomeClaw", "version":AppConfig.version]]])
        }
        if method == "ping" { return jsonData(["jsonrpc":"2.0", "id":id, "result":[String: Any]()]) }
        if method == "tools/list" { return jsonData(["jsonrpc":"2.0", "id":id, "result":["tools":advertisedTools()]]) }
        guard method == "tools/call" else { return Self.jsonRPCErrorData(id: id, code: -32601, message: "Method not found") }
        guard let params = json["params"] as? [String: Any], let name = params["name"] as? String else { return Self.jsonRPCErrorData(id: id, code: -32602, message: "Invalid params") }
        let rawArguments = params["arguments"] ?? [String: Any]()
        guard let arguments = rawArguments as? [String: Any],
              advertisedTools().contains(where: { $0["name"] as? String == name }),
              toolPolicy.allowsCall(name: name, arguments: arguments),
              let rule = toolPolicy.rule(for: name) else { return Self.jsonRPCErrorData(id: id, code: -32602, message: "Invalid params") }
        // HomeKit handlers park on waitForReady() until homes load; fail fast
        // instead of accumulating tasks that may never resume.
        if rule.requiresHomeKit && !homeKitReady { return Self.jsonRPCErrorData(id: id, code: -32002, message: "HomeKit not ready") }
        // The slot is held by the dispatched operation itself, not by this
        // request: a call that times out or whose client disconnects keeps its
        // slot until the underlying work really ends, so abandoned work cannot
        // pile up beyond the cap.
        guard let slot = toolAdmission.acquire() else { return Self.jsonRPCErrorData(id: id, code: -32003, message: "Server busy: too many concurrent tool calls") }
        let args = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
        let data = await dispatchWithTimeout(name: name, arguments: args, slot: slot)
        let isError = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] != nil
        return jsonData(["jsonrpc":"2.0", "id":id, "result":["content":[["type":"text", "text":String(decoding:data, as: UTF8.self)]], "isError":isError]])
    }
    private func dispatchWithTimeout(name: String, arguments: Data, slot: ToolDispatchAdmission.Slot) async -> Data {
        let registry = toolRegistry
        return await DispatchTimeoutRace.run(timeout: dispatchTimeout, timeoutValue: Data("{\"error\":\"Tool dispatch timed out\"}".utf8), cancelledValue: Data("{\"error\":\"Tool dispatch cancelled\"}".utf8)) {
            // Only this closure retains `slot`; it is released when the closure
            // is (after the work task finishes, or at once if it never started).
            withExtendedLifetime(slot) {}
            return await registry.call(name: name, arguments: arguments)
        }
    }
}

/// Server-wide cap on tool operations actually running. A `Slot` releases its
/// capacity when it is deallocated, so it lives exactly as long as whatever
/// retains it (the dispatched operation's closure).
final class ToolDispatchAdmission: @unchecked Sendable {
    final class Slot: @unchecked Sendable {
        private let admission: ToolDispatchAdmission
        fileprivate init(_ admission: ToolDispatchAdmission) { self.admission = admission }
        deinit { admission.release() }
    }

    private let lock = NSLock()
    private let limit: Int
    private var active = 0

    init(limit: Int) { self.limit = limit }

    var activeCount: Int { lock.lock(); defer { lock.unlock() }; return active }

    func acquire() -> Slot? {
        lock.lock()
        guard active < limit else { lock.unlock(); return nil }
        active += 1
        lock.unlock()
        return Slot(self)
    }

    fileprivate func release() { lock.lock(); active -= 1; lock.unlock() }
}

/// Races an operation against a timeout without waiting on the loser, and
/// propagates cancellation: if the awaiting task is cancelled (for example the
/// HTTP client disconnected), the race resolves to `cancelledValue` right away
/// and the operation's task is cancelled.
final class DispatchTimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Value?
    private var work: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var continuation: CheckedContinuation<Value, Never>?

    private init() {}

    static func run(
        timeout: Duration,
        timeoutValue: Value,
        cancelledValue: Value? = nil,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        let race = DispatchTimeoutRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard race.install(continuation) else { return }
                let work = Task { race.finish(with: await operation()) }
                let sleeper = Task {
#if DEBUG
                    DispatchTimeoutDebug.sleeperStarted()
                    defer { DispatchTimeoutDebug.sleeperFinished() }
#endif
                    do { try await Task.sleep(for: timeout) } catch { return }
                    race.finish(with: timeoutValue)
                }
                race.install(work: work, sleeper: sleeper)
            }
        } onCancel: {
            race.finish(with: cancelledValue ?? timeoutValue)
        }
    }

    /// Stores the continuation, or resumes it at once when the race already
    /// resolved (cancellation arrived first). Returns whether to start racing.
    private func install(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    private func install(work: Task<Void, Never>, sleeper: Task<Void, Never>) {
        lock.lock()
        if result != nil {
            lock.unlock()
            work.cancel(); sleeper.cancel()
        } else {
            self.work = work; self.sleeper = sleeper
            lock.unlock()
        }
    }

    /// First caller wins; both racers are cancelled and the continuation (if
    /// installed yet) is resumed exactly once.
    private func finish(with value: Value) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let work = self.work, sleeper = self.sleeper, continuation = self.continuation
        self.work = nil; self.sleeper = nil; self.continuation = nil
        lock.unlock()

        work?.cancel(); sleeper?.cancel()
        continuation?.resume(returning: value)
    }
}

#if DEBUG
private enum DispatchTimeoutDebug {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeSleeperTasks = 0

    static func sleeperStarted() { lock.lock(); activeSleeperTasks += 1; lock.unlock() }
    static func sleeperFinished() { lock.lock(); activeSleeperTasks -= 1; lock.unlock() }
    static var activeSleeperCount: Int { lock.lock(); defer { lock.unlock() }; return activeSleeperTasks }
}

extension MCPServer {
    static var testActiveTimeoutSleeperCount: Int { DispatchTimeoutDebug.activeSleeperCount }
}
#endif

private extension MCPServer {
    func advertisedTools() -> [[String: Any]] {
        toolPolicy.advertisedTools(from: (try? JSONSerialization.jsonObject(with: toolRegistry.toolsJSON)) as? [[String: Any]] ?? [])
    }

    /// Validates `MCP-Protocol-Version` on a post-initialize request. A present
    /// header must name a supported revision (400 otherwise, per spec). An absent
    /// header falls back to the version negotiated at initialize, which the spec
    /// allows as the server's "other way to identify the version".
    func protocolVersionError(_ request: HTTPRequest, session: StreamableHTTPSession) -> HTTPResponse? {
        let version = request.header("MCP-Protocol-Version")?.trimmingCharacters(in: .whitespaces) ?? session.protocolVersion
        return Self.supportedProtocolVersions.contains(version) ? nil : protocolError(status: 400, code: -32600, message: "Unsupported MCP-Protocol-Version")
    }

    private func protocolError(status: Int, code: Int, message: String, headers: [String:String] = [:]) -> HTTPResponse { return HTTPResponse(statusCode: status, headers: headers.merging(["Content-Type":"application/json; charset=utf-8"]) { _, new in new }, bodyData: Self.jsonRPCErrorData(code: code, message: message)) }
    private func jsonData(_ value: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: value)) ?? Data() }
    static func jsonRPCErrorData(id: Any? = nil, code: Int, message: String) -> Data { var object: [String: Any] = ["jsonrpc":"2.0", "error":["code":code, "message":message]]; if let id { object["id"] = id }; return (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }
    private struct AcceptRange {
        let mediaType: String
        let quality: Double
    }

    private func accepts(_ value: String?) -> Bool {
        ["application/json", "text/event-stream"].contains { acceptedMediaType($0, in: value) }
    }

    private func acceptsJSON(_ value: String?) -> Bool {
        acceptedMediaType("application/json", in: value)
    }

    private func acceptsEventStream(_ value: String?) -> Bool {
        acceptedMediaType("text/event-stream", in: value)
    }

    private func acceptedMediaType(_ mediaType: String, in value: String?) -> Bool {
        guard let value else { return false }
        let ranges = value.split(separator: ",").compactMap(parseAcceptRange)
        let normalizedMediaType = mediaType.lowercased()
        let matching = ranges.filter { $0.mediaType == normalizedMediaType || $0.mediaType == "*/*" }
        guard let range = matching.max(by: {
            let leftSpecificity = specificity(of: $0.mediaType)
            let rightSpecificity = specificity(of: $1.mediaType)
            return leftSpecificity == rightSpecificity ? $0.quality < $1.quality : leftSpecificity < rightSpecificity
        }) else { return false }
        return range.quality > 0
    }

    private func parseAcceptRange(_ raw: Substring) -> AcceptRange? {
        let parts = raw.split(separator: ";", omittingEmptySubsequences: true)
        guard let mediaTypePart = parts.first else { return nil }
        let mediaType = mediaTypePart.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard mediaType == "*/*" || ["application/json", "text/event-stream"].contains(mediaType) else { return nil }
        var quality = 1.0
        for parameter in parts.dropFirst() {
            let keyValue = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2 else { continue }
            let key = keyValue[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key == "q" else { continue }
            guard let parsed = Double(keyValue[1].trimmingCharacters(in: .whitespacesAndNewlines)), (0...1).contains(parsed) else { return nil }
            quality = parsed
        }
        return AcceptRange(mediaType: mediaType, quality: quality)
    }

    private func specificity(of mediaType: String) -> Int { mediaType == "*/*" ? 0 : 1 }
    private func contentTypeIsJSON(_ value: String?) -> Bool {
        guard let value, let mediaType = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first else { return false }
        return mediaType.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("application/json") == .orderedSame
    }
    private func isJSONRPC(_ json: [String: Any]) -> Bool { json["jsonrpc"] as? String == "2.0" && json["method"] is String }
}
