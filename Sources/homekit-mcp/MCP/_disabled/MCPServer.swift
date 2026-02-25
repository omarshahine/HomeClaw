import Foundation
import Logging
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

/// Manages the MCP HTTP server lifecycle and session management.
/// Modeled after the MCP SDK's conformance test HTTPApp, with bearer token auth added.
actor MCPServer {
    private var channel: Channel?
    private var sessions: [String: SessionContext] = [:]
    private let logger = Logger(label: "com.shahine.homeclaw.mcp")

    struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    // MARK: - Lifecycle

    func start() async throws {
        let port = AppConfig.port
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(MCPHTTPHandler(server: self))
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 1)

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()
        self.channel = channel

        AppLogger.mcp.info("MCP server started on port \(port)")

        // Start session cleanup loop
        Task { await sessionCleanupLoop() }

        // Block until shutdown
        try await channel.closeFuture.get()
    }

    func stop() async {
        await closeAllSessions()
        try? await channel?.close()
        channel = nil
        AppLogger.mcp.info("MCP server stopped")
    }

    // MARK: - Request Handling

    var endpoint: String { AppConfig.mcpEndpoint }

    func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        // Validate bearer token on all requests
        guard BearerTokenValidator.validate(authorizationHeader: request.header("Authorization")) else {
            return .error(statusCode: 401, .invalidRequest("Unauthorized: Invalid or missing bearer token"))
        }

        let sessionID = request.header(HTTPHeaderName.sessionID)

        // Route to existing session
        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session

            let response = await session.transport.handleRequest(request)

            // Clean up on DELETE
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
            }

            return response
        }

        // No session — check for initialize request
        if request.method.uppercased() == "POST",
           let body = request.body,
           isInitializeRequest(body)
        {
            return await createSessionAndHandle(request)
        }

        // No session and not initialize
        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Session not found or expired"))
        }
        return .error(
            statusCode: 400,
            .invalidRequest("Missing \(HTTPHeaderName.sessionID) header")
        )
    }

    // MARK: - Session Management

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            logger: logger
        )

        do {
            let server = await createServer()

            try await server.start(transport: transport)

            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date()
            )

            let response = await transport.handleRequest(request)

            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }

            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to create session: \(error.localizedDescription)")
            )
        }
    }

    private func createServer() async -> Server {
        let server = Server(
            name: AppConfig.appName,
            version: AppConfig.version,
            capabilities: Server.Capabilities(
                tools: .init(listChanged: false)
            )
        )
        await ToolHandlers.register(on: server)
        return server
    }

    private func closeAllSessions() async {
        for sessionID in sessions.keys {
            if let session = sessions.removeValue(forKey: sessionID) {
                await session.transport.disconnect()
            }
        }
    }

    private func sessionCleanupLoop() async {
        let timeout: TimeInterval = 3600
        while true {
            try? await Task.sleep(for: .seconds(60))
            let now = Date()
            let expired = sessions.filter { now.timeIntervalSince($0.value.lastAccessedAt) > timeout }
            for (sessionID, _) in expired {
                AppLogger.mcp.info("Session expired: \(sessionID)")
                if let session = sessions.removeValue(forKey: sessionID) {
                    await session.transport.disconnect()
                }
            }
        }
    }

    // MARK: - JSON-RPC Helpers

    /// Detects if a POST body is a JSON-RPC "initialize" request.
    /// JSONRPCMessageKind is package-internal to the MCP SDK, so we replicate the check.
    private func isInitializeRequest(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String
        else {
            return false
        }
        return method == "initialize"
    }
}
