import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1

final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart; typealias OutboundOut = HTTPServerResponsePart
    private let server: MCPServer; private let maximumBodyBytes = 1_048_576
    private struct RequestState: Sendable { var head: HTTPRequestHead; var bodyBuffer: ByteBuffer; let responseTicket: Int }
    private var requestState: RequestState?; private var rejectedBody = false
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private let maxInflight: Int
    private let lifecycle = MCPHTTPHandlerLifecycle()
    private let responseOrder = MCPHTTPResponseOrder()
    private let tracker: MCPHTTPConnectionTracker
    init(server: MCPServer, tracker: MCPHTTPConnectionTracker = MCPHTTPConnectionTracker(), maxInflight: Int = HTTPMCPConfiguration.defaultMaxInflightPerChannel) {
        self.server = server; self.tracker = tracker; self.maxInflight = maxInflight
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            rejectedBody = false
            let responseTicket = responseOrder.reserve()
            if let length = head.headers.first(name: "Content-Length").flatMap(Int.init), length > maximumBodyBytes {
                rejectedBody = true; requestState = nil
                Self.schedule(.error(statusCode: 413, "Request body too large"), version: head.version, on: context.channel, order: responseOrder, ticket: responseTicket, tracker: tracker)
                return
            }
            requestState = RequestState(head: head, bodyBuffer: context.channel.allocator.buffer(capacity: 0), responseTicket: responseTicket)
        case .body(var buffer):
            guard !rejectedBody else { return }
            guard var state = requestState, buffer.readableBytes <= maximumBodyBytes, state.bodyBuffer.readableBytes + buffer.readableBytes <= maximumBodyBytes else {
                rejectedBody = true; let version = requestState?.head.version ?? .http1_1; let ticket = requestState?.responseTicket
                requestState = nil
                if let ticket { Self.schedule(.error(statusCode: 413, "Request body too large"), version: version, on: context.channel, order: responseOrder, ticket: ticket, tracker: tracker) }
                return
            }
            state.bodyBuffer.writeBuffer(&buffer); requestState = state
        case .end:
            guard !rejectedBody, let state = requestState else { requestState = nil; rejectedBody = false; return }
            // Bound pipelined work per channel — 1 MiB per request does not bound aggregate
            if activeTasks.count >= maxInflight {
                let ticket = state.responseTicket; requestState = nil
                Self.schedule(.error(statusCode: 429, "Too many concurrent requests"), version: state.head.version, on: context.channel, order: responseOrder, ticket: ticket, tracker: tracker)
                return
            }
            requestState = nil; let taskID = UUID(); let sessionID = state.head.headers.first(name: "Mcp-Session-Id"); lifecycle.begin(taskID: taskID, sessionID: sessionID)
            let channel = context.channel
            let responseOrder = self.responseOrder
            let responseTicket = state.responseTicket
            let tracker = self.tracker
            let task = Task { [weak self, server, state, channel, responseOrder, responseTicket, tracker] in
                defer {
                    responseOrder.finish(responseTicket)
                    channel.eventLoop.execute { [weak self] in self?.lifecycle.finish(taskID: taskID); self?.activeTasks.removeValue(forKey: taskID) }
                    // Last: MCPServer.stop() waits for this before shutting the loop down.
                    tracker.finish(taskID)
                }
                guard channel.isActive, let self else { return }
                let request = Self.makeHTTPRequest(from: state)
                let response: HTTPResponse
                if let host = request.header("Host") {
                    do { try HTTPMCPRequestPolicy.validate(host: host, origin: request.header("Origin"), bindHost: await server.bindHost); response = await server.handleHTTPRequest(request) }
                    catch HTTPMCPRequestPolicy.ValidationError.invalidOrigin, HTTPMCPRequestPolicy.ValidationError.nonLoopbackOrigin {
                        // MCP 2025-11-25: an invalid Origin MUST get 403 Forbidden.
                        response = .error(statusCode: 403, "Forbidden origin")
                    }
                    catch { response = .error(statusCode: 400, "Invalid request policy") }
                } else { response = .error(statusCode: 400, "Invalid request policy") }
                guard !Task.isCancelled, channel.isActive else {
                    await Self.cleanupCancelledRequestIfNeeded(sseOwnership: response.sseOwnership, isCancelled: true) { await server.cleanupSSE(for: $0) }
                    return
                }
                if let ownership = response.sseOwnership {
                    channel.eventLoop.execute { [weak self] in
                        // channelInactive may have run before this queued handoff.
                        guard channel.isActive else { return }
                        self?.lifecycle.markSSEActive(ownership)
                    }
                }
                await Self.writeOrdered(response, version: state.head.version, channel: channel, order: responseOrder, ticket: responseTicket)
                if let ownership = response.sseOwnership {
                    // The response task owns this token even before event-loop
                    // registration. Always retire it on exit: cancellation can
                    // race the guard above or occur while waiting for FIFO writes.
                    // Token matching leaves a newer connection's stream intact.
                    await server.cleanupSSE(for: ownership)
                    channel.eventLoop.execute { [weak self] in self?.lifecycle.finishSSE(ownership) }
                }
            }
            activeTasks[taskID] = task
            tracker.track(taskID, task)
        }
    }

    /// Closes a connection that has read nothing for the configured timeout.
    /// That includes a partial request (headers, or part of a body, then a
    /// stall): it has no task yet, and leaving it open would let a handful of
    /// stalled sockets hold the connection cap. Connections with an executing
    /// request or a live SSE stream (whose writer task stays in `activeTasks`)
    /// are left open.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            if activeTasks.isEmpty { requestState = nil; context.close(promise: nil) }
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        activeTasks.values.forEach { $0.cancel() }; activeTasks.removeAll(); responseOrder.cancelAll(); let ownerships = lifecycle.cancelAll(); requestState = nil; rejectedBody = false
        Task { for ownership in ownerships { await server.cleanupSSE(for: ownership) } }
    }
    static func cleanupCancelledRequestIfNeeded(sseOwnership: SSEStreamOwnership?, isCancelled: Bool, cleanup: @escaping @Sendable (SSEStreamOwnership) async -> Void) async { guard isCancelled, let sseOwnership else { return }; await cleanup(sseOwnership) }
    static func normalizedHeaders(from headers: HTTPHeaders) -> [String: String] {
        var normalized: [String: String] = [:]
        for (name, value) in headers {
            if let existing = normalized.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }) {
                normalized[existing.key] = "\(existing.value), \(value)"
            } else {
                normalized[name] = value
            }
        }
        return normalized
    }

    private static func makeHTTPRequest(from state: RequestState) -> HTTPRequest {
        let body = state.bodyBuffer.readableBytes > 0 ? state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes).map { Data(bytes: $0) } : nil
        return HTTPRequest(method: state.head.method.rawValue, uri: state.head.uri, headers: normalizedHeaders(from: state.head.headers), body: body)
    }
    private static func schedule(_ response: HTTPResponse, version: HTTPVersion, on channel: Channel, order: MCPHTTPResponseOrder, ticket: Int, tracker: MCPHTTPConnectionTracker) {
        let id = UUID()
        let task = Task {
            defer { tracker.finish(id) }
            await order.waitTurn(ticket)
            defer { order.finish(ticket) }
            channel.eventLoop.execute {
                guard channel.isActive else { return }
                writeParts(response, version: version, channel: channel)
                channel.writeAndFlush(wrapOutbound(.end(nil)), promise: nil)
            }
        }
        tracker.track(id, task)
    }
    private static func writeOrdered(_ response: HTTPResponse, version: HTTPVersion, channel: Channel, order: MCPHTTPResponseOrder, ticket: Int) async {
        await order.waitTurn(ticket)
        defer { order.finish(ticket) }
        await write(response, version: version, channel: channel)
    }
    private static func write(_ response: HTTPResponse, version: HTTPVersion, channel: Channel) async {
        await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled, channel.isActive else { return }
            await writePartsAsync(response, version: version, channel: channel)
        }, onCancel: {})
    }
    private static func writePartsAsync(_ response: HTTPResponse, version: HTTPVersion, channel: Channel) async {
        channel.eventLoop.execute { guard channel.isActive else { return }; writeParts(response, version: version, channel: channel) }
        if let stream = response.stream {
            for await chunk in stream {
                if Task.isCancelled { return }
                channel.eventLoop.execute { guard channel.isActive else { return }; var buffer = channel.allocator.buffer(capacity: chunk.count); buffer.writeBytes(chunk); channel.writeAndFlush(Self.wrapOutbound(.body(.byteBuffer(buffer))), promise: nil) }
            }
        }
        guard !Task.isCancelled else { return }
        channel.eventLoop.execute { guard channel.isActive else { return }; channel.writeAndFlush(Self.wrapOutbound(.end(nil)), promise: nil) }
    }
    private static func writeParts(_ response: HTTPResponse, version: HTTPVersion, channel: Channel) {
        var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: response.statusCode))
        // Fixed-size responses always carry Content-Length, 0 for an empty body
        // (202 notification acks, DELETE), so the encoder never falls back to
        // chunked framing for a response that has no body.
        if response.stream == nil {
            head.headers.add(name: "Content-Length", value: "\(response.bodyData?.count ?? 0)")
        }
        for (name, value) in response.headers { head.headers.add(name: name, value: value) }
        channel.write(wrapOutbound(.head(head)), promise: nil)
        if response.stream == nil, let body = response.bodyData { var buffer = channel.allocator.buffer(capacity: body.count); buffer.writeBytes(body); channel.write(wrapOutbound(.body(.byteBuffer(buffer))), promise: nil) }
        if response.stream != nil { channel.flush() }
    }
    private static func wrapOutbound(_ part: HTTPServerResponsePart) -> NIOAny { NIOAny(part) }
}
