import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1

final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart; typealias OutboundOut = HTTPServerResponsePart
    private let server: MCPServer; private let maximumBodyBytes = 1_048_576
    private struct RequestState: Sendable { var head: HTTPRequestHead; var bodyBuffer: ByteBuffer; let responseTicket: Int }
    private var requestState: RequestState?; private var rejectedBody = false
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private let maxInflight = HTTPMCPConfiguration.defaultMaxInflightPerChannel
    private let lifecycle = MCPHTTPHandlerLifecycle()
    private let responseOrder = MCPHTTPResponseOrder()
    init(server: MCPServer) { self.server = server }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            rejectedBody = false
            let responseTicket = responseOrder.reserve()
            if let length = head.headers.first(name: "Content-Length").flatMap(Int.init), length > maximumBodyBytes {
                rejectedBody = true; requestState = nil
                Self.schedule(.error(statusCode: 413, "Request body too large"), version: head.version, on: context.channel, order: responseOrder, ticket: responseTicket)
                return
            }
            requestState = RequestState(head: head, bodyBuffer: context.channel.allocator.buffer(capacity: 0), responseTicket: responseTicket)
        case .body(var buffer):
            guard !rejectedBody else { return }
            guard var state = requestState, buffer.readableBytes <= maximumBodyBytes, state.bodyBuffer.readableBytes + buffer.readableBytes <= maximumBodyBytes else {
                rejectedBody = true; let version = requestState?.head.version ?? .http1_1; let ticket = requestState?.responseTicket
                requestState = nil
                if let ticket { Self.schedule(.error(statusCode: 413, "Request body too large"), version: version, on: context.channel, order: responseOrder, ticket: ticket) }
                return
            }
            state.bodyBuffer.writeBuffer(&buffer); requestState = state
        case .end:
            guard !rejectedBody, let state = requestState else { requestState = nil; rejectedBody = false; return }
            // Bound pipelined work per channel — 1 MiB per request does not bound aggregate
            if activeTasks.count >= maxInflight {
                let ticket = state.responseTicket; requestState = nil
                Self.schedule(.error(statusCode: 429, "Too many concurrent requests"), version: state.head.version, on: context.channel, order: responseOrder, ticket: ticket)
                return
            }
            requestState = nil; let taskID = UUID(); let sessionID = state.head.headers.first(name: "Mcp-Session-Id"); lifecycle.begin(taskID: taskID, sessionID: sessionID)
            let channel = context.channel
            let responseOrder = self.responseOrder
            let responseTicket = state.responseTicket
            let task = Task { [weak self, server, state, channel, responseOrder, responseTicket] in
                defer {
                    responseOrder.finish(responseTicket)
                    channel.eventLoop.execute { [weak self] in self?.lifecycle.finish(taskID: taskID); self?.activeTasks.removeValue(forKey: taskID) }
                }
                guard channel.isActive, let self else { return }
                let request = Self.makeHTTPRequest(from: state)
                let response: HTTPResponse
                if let host = request.header("Host") {
                    do { try HTTPMCPRequestPolicy.validate(host: host, origin: request.header("Origin"), bindHost: await server.bindHost); response = await server.handleHTTPRequest(request) }
                    catch { response = .error(statusCode: 400, "Invalid request policy") }
                } else { response = .error(statusCode: 400, "Invalid request policy") }
                await Self.cleanupCancelledRequestIfNeeded(sseOwnership: response.sseOwnership, isCancelled: Task.isCancelled) { await server.cleanupSSE(for: $0) }
                guard !Task.isCancelled, channel.isActive else { return }
                if let ownership = response.sseOwnership { channel.eventLoop.execute { [weak self] in self?.lifecycle.markSSEActive(ownership) } }
                await Self.writeOrdered(response, version: state.head.version, channel: channel, order: responseOrder, ticket: responseTicket)
                if let ownership = response.sseOwnership { channel.eventLoop.execute { [weak self] in self?.lifecycle.finishSSE(ownership) } }
            }
            activeTasks[taskID] = task
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        activeTasks.values.forEach { $0.cancel() }; activeTasks.removeAll(); responseOrder.cancelAll(); let sessions = lifecycle.cancelAll(); requestState = nil; rejectedBody = false
        Task { await server.cleanupSSE(for: sessions) }
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
    private static func schedule(_ response: HTTPResponse, version: HTTPVersion, on channel: Channel, order: MCPHTTPResponseOrder, ticket: Int) {
        Task {
            await order.waitTurn(ticket)
            defer { order.finish(ticket) }
            channel.eventLoop.execute {
                guard channel.isActive else { return }
                writeParts(response, version: version, channel: channel)
                channel.writeAndFlush(wrapOutbound(.end(nil)), promise: nil)
            }
        }
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
        // Add Content-Length for fixed-size non-stream responses (HTTP/1.1 framing)
        if let body = response.bodyData, response.stream == nil {
            head.headers.add(name: "Content-Length", value: "\(body.count)")
        }
        for (name, value) in response.headers { head.headers.add(name: name, value: value) }
        channel.write(wrapOutbound(.head(head)), promise: nil)
        if response.stream == nil, let body = response.bodyData { var buffer = channel.allocator.buffer(capacity: body.count); buffer.writeBytes(body); channel.write(wrapOutbound(.body(.byteBuffer(buffer))), promise: nil) }
        if response.stream != nil { channel.flush() }
    }
    private static func wrapOutbound(_ part: HTTPServerResponsePart) -> NIOAny { NIOAny(part) }
}
