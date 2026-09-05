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
    static let supportedProtocolVersion = "2025-06-18"
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
    private static let readOnlyTools: Set<String> = ["homekit_status", "homekit_accessories", "homekit_rooms", "homekit_device_map", "homekit_events"]

    init(configuration: HTTPMCPConfiguration = .init(port: AppConfig.mcpPort, bindHost: AppConfig.mcpBindHost), homeKitReady: Bool = false, sessionStore: StreamableHTTPSessionStore? = nil, toolRegistry: MCPToolRegistry = HomeClawMCPToolRegistry.shared, dispatchTimeout: Duration = .seconds(120)) {
        self.configuration = configuration; self.homeKitReady = homeKitReady; self.toolRegistry = toolRegistry; self.dispatchTimeout = dispatchTimeout
        self.sessionStore = sessionStore ?? .init(ttl: configuration.sessionTTL, maxSessions: configuration.maxSessions)
    }
    var endpoint: String { AppConfig.mcpEndpoint }; var bindHost: String { configuration.bindHost }
    func updateHomeKitReady(_ ready: Bool) { homeKitReady = ready; NotificationCenter.default.post(name: .mcpListenerStatusDidChange, object: nil, userInfo: ["listenerReady": listenerReady, "homeKitReady": ready]) }

    func start() async throws {
        guard channel == nil, !isStarting else { return }; try configuration.validateLoopbackBind()
        isStarting = true; defer { isStarting = false }
        let generation = lifecycleGeneration
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ServerBootstrap(group: group).serverChannelOption(.backlog, value: 256).serverChannelOption(.socketOption(.so_reuseaddr), value: 1).childChannelInitializer { channel in channel.pipeline.configureHTTPServerPipeline().flatMap { channel.pipeline.addHandler(MCPHTTPHandler(server: self)) } }.bind(host: configuration.bindHost, port: configuration.port).get()
            guard generation == lifecycleGeneration else {
                try? await channel.close()
                try? await group.shutdownGracefully()
                return
            }
            self.group = group; self.channel = channel; listenerReady = true; startExpiryCleanup()
            NotificationCenter.default.post(name: .mcpListenerStatusDidChange, object: nil, userInfo: ["listenerReady": true, "homeKitReady": homeKitReady])
        } catch { try? await group.shutdownGracefully(); throw error }
    }
    func stop() async {
        lifecycleGeneration &+= 1
        let channel = self.channel; let group = self.group; self.channel = nil; self.group = nil; listenerReady = false
        expiryTask?.cancel(); expiryTask = nil; cleanupSSE(for: Array(sseContinuations.keys)); _ = await sessionStore.removeAll()
        NotificationCenter.default.post(name: .mcpListenerStatusDidChange, object: nil, userInfo: ["listenerReady": false, "homeKitReady": homeKitReady])
        if let channel { try? await channel.close() }; if let group { try? await group.shutdownGracefully() }
    }
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
        guard await sessionStore.validateAndTouch(id) else { return protocolError(status: 404, code: -32600, message: "Session not found or expired") }
        guard request.header("MCP-Protocol-Version") == Self.supportedProtocolVersion else { return protocolError(status: 400, code: -32600, message: "Unsupported or missing MCP-Protocol-Version") }
        if method == "DELETE" { cleanupSSE(for: id); _ = await sessionStore.remove(id); return HTTPResponse(statusCode: 200) }
        var continuation: AsyncStream<Data>.Continuation!; let stream = AsyncStream<Data> { continuation = $0 }; continuation.yield(Data(": connected\n\n".utf8)); let ownership = SSEStreamOwnership(sessionID: id, token: UUID())
        sseContinuations.removeValue(forKey: id)?.continuation.finish(); sseContinuations[id] = (ownership, continuation)
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
            guard request.header("MCP-Protocol-Version") == Self.supportedProtocolVersion else { return protocolError(status: 400, code: -32600, message: "Unsupported or missing MCP-Protocol-Version") }
            guard let supplied else { return protocolError(status: 400, code: -32600, message: "Missing Mcp-Session-Id header") }
            guard await sessionStore.validateAndTouch(supplied) else { return protocolError(status: 404, code: -32600, message: "Session not found or expired") }
            if isNotification { return HTTPResponse(statusCode: 202) }
        }
        let id: String
        if let supplied {
            id = supplied
        } else {
            guard let created = await sessionStore.create() else {
                return protocolError(status: 429, code: -32600, message: "Too many sessions")
            }
            id = created
        }
        guard !isNotification else { return HTTPResponse(statusCode: 202) }
        var headers = ["Content-Type": "application/json; charset=utf-8"]; if supplied == nil { headers["Mcp-Session-Id"] = id }
        return HTTPResponse(statusCode: 200, headers: headers, bodyData: await rpcResponse(for: json))
    }

    private func validateInitializeParams(_ json: [String: Any]) -> HTTPResponse? {
        guard let params = json["params"] as? [String: Any] else {
            return protocolError(status: 400, code: -32602, message: "Missing initialize params")
        }
        guard let pv = params["protocolVersion"] as? String, pv == Self.supportedProtocolVersion else {
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
        if method == "initialize" { return jsonData(["jsonrpc":"2.0", "id":id, "result":["protocolVersion":Self.supportedProtocolVersion, "capabilities":["tools":["listChanged":false]], "serverInfo":["name":"HomeClaw", "version":AppConfig.version]]]) }
        if method == "tools/list" { return jsonData(["jsonrpc":"2.0", "id":id, "result":["tools":advertisedReadOnlyTools()]]) }
        guard method == "tools/call" else { return Self.jsonRPCErrorData(id: id, code: -32601, message: "Method not found") }
        guard let params = json["params"] as? [String: Any], let name = params["name"] as? String, advertisedReadOnlyTools().contains(where: { $0["name"] as? String == name }), Self.isReadOnlyCall(name: name, arguments: params["arguments"] as? [String: Any] ?? [:]) else { return Self.jsonRPCErrorData(id: id, code: -32602, message: "Invalid params") }
        let args = (try? JSONSerialization.data(withJSONObject: params["arguments"] as? [String: Any] ?? [:])) ?? Data("{}".utf8)
        let data = await dispatchWithTimeout(name: name, arguments: args)
        let isError = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] != nil
        return jsonData(["jsonrpc":"2.0", "id":id, "result":["content":[["type":"text", "text":String(decoding:data, as: UTF8.self)]], "isError":isError]])
    }
    private func dispatchWithTimeout(name: String, arguments: Data) async -> Data {
        await DispatchTimeoutRace.run(timeout: dispatchTimeout, timeoutValue: Data("{\"error\":\"Tool dispatch timed out\"}".utf8)) {
            await self.toolRegistry.call(name: name, arguments: arguments)
        }
    }
}

final class DispatchTimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var work: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private let continuation: CheckedContinuation<Value, Never>

    private init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    static func run(
        timeout: Duration,
        timeoutValue: Value,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            let race = DispatchTimeoutRace(continuation)
            let work = Task { race.finish(with: await operation(), cancelling: .sleeper) }
            let sleeper = Task {
#if DEBUG
                DispatchTimeoutDebug.sleeperStarted()
                defer { DispatchTimeoutDebug.sleeperFinished() }
#endif
                do { try await Task.sleep(for: timeout) } catch { return }
                race.finish(with: timeoutValue, cancelling: .work)
            }
            race.install(work: work, sleeper: sleeper)
        }
    }

    private enum Loser { case work, sleeper }

    private func install(work: Task<Void, Never>, sleeper: Task<Void, Never>) {
        lock.lock()
        if completed {
            lock.unlock()
            work.cancel(); sleeper.cancel()
        } else {
            self.work = work; self.sleeper = sleeper
            lock.unlock()
        }
    }

    private func finish(with value: Value, cancelling loser: Loser) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let work = self.work
        let sleeper = self.sleeper
        self.work = nil; self.sleeper = nil
        lock.unlock()

        switch loser {
        case .work: work?.cancel()
        case .sleeper: sleeper?.cancel()
        }
        continuation.resume(returning: value)
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
    func advertisedReadOnlyTools() -> [[String: Any]] {
        ((try? JSONSerialization.jsonObject(with: toolRegistry.toolsJSON)) as? [[String: Any]] ?? [])
            .filter { Self.readOnlyTools.contains($0["name"] as? String ?? "") }
            .map { tool in
                guard tool["name"] as? String == "homekit_accessories",
                      var schema = tool["inputSchema"] as? [String: Any],
                      var properties = schema["properties"] as? [String: Any],
                      var action = properties["action"] as? [String: Any],
                      let actions = action["enum"] as? [Any] else { return tool }
                action["enum"] = actions.filter { $0 as? String != "control" }
                properties["action"] = action
                schema["properties"] = properties
                var filteredTool = tool
                filteredTool["inputSchema"] = schema
                return filteredTool
            }
    }

    static func isReadOnlyCall(name: String, arguments: [String: Any]) -> Bool {
        guard name == "homekit_accessories" else { return true }
        return ["list", "get", "search"].contains(arguments["action"] as? String ?? "list")
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
    private func contentTypeIsJSON(_ value: String?) -> Bool { value?.split(separator: ";", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("application/json") == .orderedSame }
    private func isJSONRPC(_ json: [String: Any]) -> Bool { json["jsonrpc"] as? String == "2.0" && json["method"] is String }
}
