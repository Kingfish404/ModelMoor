import Darwin
import Foundation
import ModelMoorCore
import NIOCore
import NIOHTTP1
import NIOPosix

public enum GatewayServiceState: Equatable, Sendable {
    case stopped
    case running(port: Int)
    case failed(String)
}

public final class GatewayService: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let limiter: GatewayRequestLimiter
    private let usageHandler: (@Sendable (GatewayTokenUsage) -> Void)?
    private let upstreamCancellationObserver: (@Sendable () -> Void)?
    private let connections = GatewayConnectionRegistry()
    private let lock = NSLock()
    private var serverChannel: Channel?
    private var currentState: GatewayServiceState = .stopped

    public convenience init(
        maximumActiveRequests: Int = 64,
        usageHandler: (@Sendable (GatewayTokenUsage) -> Void)? = nil
    ) {
        self.init(
            maximumActiveRequests: maximumActiveRequests,
            usageHandler: usageHandler,
            upstreamCancellationObserver: nil
        )
    }

    init(
        maximumActiveRequests: Int = 64,
        usageHandler: (@Sendable (GatewayTokenUsage) -> Void)? = nil,
        upstreamCancellationObserver: (@Sendable () -> Void)?
    ) {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        limiter = GatewayRequestLimiter(limit: maximumActiveRequests)
        self.usageHandler = usageHandler
        self.upstreamCancellationObserver = upstreamCancellationObserver
    }

    deinit {
        try? serverChannel?.close().wait()
        try? group.syncShutdownGracefully()
    }

    public var state: GatewayServiceState {
        lock.withLock { currentState }
    }

    public func start(snapshot: GatewaySnapshot) async throws {
        _ = try snapshot.configuration.validated()
        guard snapshot.configuration.gateway.enabled else {
            throw GatewayServiceError.disabled
        }
        guard !snapshot.configuration.gateway.requiresAPIKey
                || snapshot.gatewayAPIKeys.contains(where: { !$0.isEmpty }) else {
            throw GatewayServiceError.missingGatewayAPIKey
        }
        if serverChannel != nil { await stop() }

        let router = GatewayRequestRouter(snapshot: snapshot)
        let limiter = self.limiter
        let connections = self.connections
        let usageHandler = self.usageHandler
        let upstreamCancellationObserver = self.upstreamCancellationObserver
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 128)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                connections.add(channel)
                channel.closeFuture.whenComplete { _ in connections.remove(channel) }
                return channel.pipeline.configureHTTPServerPipeline(
                    withPipeliningAssistance: false,
                    withErrorHandling: true
                ).flatMap {
                    channel.pipeline.addHandler(GatewayHTTPHandler(
                        router: router,
                        limiter: limiter,
                        usageHandler: usageHandler,
                        upstreamCancellationObserver: upstreamCancellationObserver
                    ))
                }
            }
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)

        do {
            let channel = try await bootstrap.bind(
                host: "127.0.0.1",
                port: snapshot.configuration.gateway.listenPort
            ).get()
            lock.withLock {
                serverChannel = channel
                currentState = .running(port: snapshot.configuration.gateway.listenPort)
            }
        } catch {
            let failure = GatewayServiceError.listenerFailure(
                error,
                port: snapshot.configuration.gateway.listenPort
            )
            lock.withLock { currentState = .failed(failure.localizedDescription) }
            throw failure
        }
    }

    public func stop() async {
        let channel = lock.withLock { () -> Channel? in
            let value = serverChannel
            serverChannel = nil
            currentState = .stopped
            return value
        }
        try? await channel?.close().get()
        await connections.closeAll()
    }
}

private final class GatewayConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]

    func add(_ channel: Channel) {
        lock.withLock { channels[ObjectIdentifier(channel)] = channel }
    }

    func remove(_ channel: Channel) {
        lock.withLock { channels[ObjectIdentifier(channel)] = nil }
    }

    func closeAll() async {
        let current = lock.withLock { () -> [Channel] in
            let values = Array(channels.values)
            channels.removeAll()
            return values
        }
        for channel in current {
            try? await channel.close().get()
        }
    }
}

/// Serializes and coalesces Gateway replacements. Callers may request another
/// snapshot while a listener is stopping or binding, but only this coordinator
/// is allowed to perform those lifecycle operations.
public actor GatewayServiceCoordinator {
    private enum Target: Equatable, Sendable {
        case stopped
        case running(GatewaySnapshot)
    }

    private let serviceFactory: @Sendable () -> GatewayService
    private var service: GatewayService?
    private var pendingTarget: Target?
    private var isReconciling = false
    private var appliedTarget: Target = .stopped
    private var appliedState: GatewayServiceState = .stopped
    private var waiters: [CheckedContinuation<GatewayServiceState, Never>] = []

    public init(
        maximumActiveRequests: Int = 64,
        usageHandler: (@Sendable (GatewayTokenUsage) -> Void)? = nil
    ) {
        serviceFactory = {
            GatewayService(
                maximumActiveRequests: maximumActiveRequests,
                usageHandler: usageHandler
            )
        }
    }

    public func reconcile(snapshot: GatewaySnapshot?) async -> GatewayServiceState {
        pendingTarget = snapshot.map(Target.running) ?? .stopped
        guard !isReconciling else {
            return await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        isReconciling = true
        var result = appliedState
        var lastProcessedTarget: Target?
        while let target = pendingTarget {
            pendingTarget = nil
            // Multiple status callbacks commonly request the same snapshot
            // during one async bind. They should share that bind, not restart it.
            guard target != lastProcessedTarget else { continue }
            // Status callbacks also arrive sequentially. Keep an already healthy
            // listener when its effective routing snapshot has not changed.
            if target == appliedTarget, appliedState.isStable {
                result = appliedState
                lastProcessedTarget = target
                continue
            }
            result = await apply(target)
            lastProcessedTarget = target
        }
        isReconciling = false

        let completedWaiters = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in completedWaiters { waiter.resume(returning: result) }
        return result
    }

    private func apply(_ target: Target) async -> GatewayServiceState {
        await service?.stop()
        service = nil
        appliedTarget = target
        guard case let .running(snapshot) = target else {
            appliedState = .stopped
            return appliedState
        }

        let replacement = serviceFactory()
        do {
            try await replacement.start(snapshot: snapshot)
            service = replacement
        } catch {
            // GatewayService records the actionable failure in its state.
        }
        appliedState = replacement.state
        return appliedState
    }
}

private extension GatewayServiceState {
    var isStable: Bool {
        switch self {
        case .stopped, .running: true
        case .failed: false
        }
    }
}

public enum GatewayServiceError: LocalizedError, Equatable {
    case disabled
    case missingGatewayAPIKey
    case listenerAddressInUse(port: Int)
    case listenerPermissionDenied(port: Int)
    case listenerFailed(port: Int, detail: String)

    public var errorDescription: String? {
        switch self {
        case .disabled: "Gateway is disabled in the current configuration."
        case .missingGatewayAPIKey: "Unified API requires an enabled API key."
        case let .listenerAddressInUse(port):
            "Unified API couldn't start because local port \(port) is already in use."
        case let .listenerPermissionDenied(port):
            "Unified API doesn't have permission to listen on local port \(port)."
        case let .listenerFailed(port, detail):
            "Unified API couldn't listen on 127.0.0.1:\(port): \(detail)"
        }
    }

    fileprivate static func listenerFailure(_ error: Error, port: Int) -> Self {
        guard let ioError = error as? IOError else {
            return .listenerFailed(port: port, detail: error.localizedDescription)
        }
        switch ioError.errnoCode {
        case EADDRINUSE: return .listenerAddressInUse(port: port)
        case EACCES, EPERM: return .listenerPermissionDenied(port: port)
        default: return .listenerFailed(port: port, detail: ioError.localizedDescription)
        }
    }
}

private actor GatewayRequestLimiter {
    let limit: Int
    private var active = 0

    init(limit: Int) { self.limit = limit }

    func acquire() -> Bool {
        guard active < limit else { return false }
        active += 1
        return true
    }

    func release() {
        active = max(0, active - 1)
    }
}

private final class GatewayHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: GatewayRequestRouter
    private let limiter: GatewayRequestLimiter
    private let usageHandler: (@Sendable (GatewayTokenUsage) -> Void)?
    private let upstreamCancellationObserver: (@Sendable () -> Void)?
    private var requestHead: HTTPRequestHead?
    private var requestBody = Data()
    private var bodyTooLarge = false
    private var responseTask: Task<Void, Never>?

    init(
        router: GatewayRequestRouter,
        limiter: GatewayRequestLimiter,
        usageHandler: (@Sendable (GatewayTokenUsage) -> Void)?,
        upstreamCancellationObserver: (@Sendable () -> Void)?
    ) {
        self.router = router
        self.limiter = limiter
        self.usageHandler = usageHandler
        self.upstreamCancellationObserver = upstreamCancellationObserver
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            guard responseTask == nil, requestHead == nil else {
                // Every response advertises Connection: close. A pipelined request
                // on the same socket would otherwise interleave two response bodies.
                responseTask?.cancel()
                responseTask = nil
                context.close(promise: nil)
                return
            }
            requestHead = head
            requestBody.removeAll(keepingCapacity: true)
            bodyTooLarge = false
        case var .body(buffer):
            guard !bodyTooLarge else { return }
            if requestBody.count + buffer.readableBytes > GatewayRequestRouter.maximumBodyBytes {
                bodyTooLarge = true
                requestBody.removeAll(keepingCapacity: false)
                return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                requestBody.append(contentsOf: bytes)
            }
        case .end:
            guard let head = requestHead else { return }
            requestHead = nil
            if bodyTooLarge {
                writeLocal(
                    GatewayLocalResponse(status: 413, body: Self.errorBody(code: "request_too_large", message: "Request body exceeds 16 MiB.")),
                    context: context
                )
                return
            }
            let headers = Dictionary(head.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { _, newest in newest })
            let request = GatewayRequest(method: head.method.rawValue, uri: head.uri, headers: headers, body: requestBody)
            requestBody.removeAll(keepingCapacity: true)
            let writer = GatewayResponseWriter(
                context: context,
                usageHandler: usageHandler,
                upstreamCancellationObserver: upstreamCancellationObserver
            )
            responseTask = Task { [router, limiter] in
                guard await limiter.acquire() else {
                    await writer.writeLocal(GatewayLocalResponse(
                        status: 503,
                        body: Self.errorBody(code: "gateway_busy", message: "Gateway has reached its 64-request concurrency limit.")
                    ))
                    return
                }
                switch router.route(request) {
                case let .local(response):
                    await writer.writeLocal(response)
                case let .upstream(prepared):
                    await writer.proxy(prepared)
                }
                await limiter.release()
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        responseTask?.cancel()
        responseTask = nil
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed {
            responseTask?.cancel()
            responseTask = nil
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        responseTask?.cancel()
        context.close(promise: nil)
    }

    private func writeLocal(_ response: GatewayLocalResponse, context: ChannelHandlerContext) {
        let writer = GatewayResponseWriter(context: context)
        responseTask = Task { await writer.writeLocal(response) }
    }

    fileprivate static func errorBody(code: String, message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "error": ["message": message, "type": "modelmoor_error", "code": code]
        ])) ?? Data()
    }
}

private final class GatewayResponseWriter: @unchecked Sendable {
    private static let sharedUpstreamSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    private let context: ChannelHandlerContext
    private let usageHandler: (@Sendable (GatewayTokenUsage) -> Void)?
    private let upstreamCancellationObserver: (@Sendable () -> Void)?

    init(
        context: ChannelHandlerContext,
        usageHandler: (@Sendable (GatewayTokenUsage) -> Void)? = nil,
        upstreamCancellationObserver: (@Sendable () -> Void)? = nil
    ) {
        self.context = context
        self.usageHandler = usageHandler
        self.upstreamCancellationObserver = upstreamCancellationObserver
    }

    func writeLocal(_ response: GatewayLocalResponse) async {
        var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
        headers.replaceOrAdd(name: "Content-Length", value: String(response.body.count))
        headers.replaceOrAdd(name: "Connection", value: "close")
        await writeHead(status: response.status, headers: headers)
        if !response.body.isEmpty { await writeBody(response.body) }
        await finish()
    }

    func proxy(_ request: GatewayPreparedRequest) async {
        let cancellation = UpstreamTaskCancellation()
        await withTaskCancellationHandler {
            await proxy(
                request,
                session: Self.sharedUpstreamSession,
                cancellation: cancellation
            )
        } onCancel: {
            // Cancel only this URLSessionTask; other clients keep their in-flight
            // requests and can continue reusing the shared HTTPS connection pool.
            cancellation.cancel()
            self.upstreamCancellationObserver?()
        }
    }

    private func proxy(
        _ request: GatewayPreparedRequest,
        session: URLSession,
        cancellation: UpstreamTaskCancellation
    ) async {
        var responseStarted = false
        var responseIsEventStream = false
        do {
            let (bytes, response) = try await session.bytes(for: request.urlRequest, delegate: cancellation)
            guard let response = response as? HTTPURLResponse else {
                await writeLocal(GatewayLocalResponse(
                    status: 502,
                    body: GatewayHTTPHandler.errorBody(code: "invalid_upstream", message: "Upstream returned an invalid response.")
                ))
                return
            }
            let blocked = Set(["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade", "content-length", "content-encoding"])
            var headers = HTTPHeaders()
            for (rawName, rawValue) in response.allHeaderFields {
                let name = String(describing: rawName)
                guard !blocked.contains(name.lowercased()) else { continue }
                headers.add(name: name, value: String(describing: rawValue))
            }
            headers.replaceOrAdd(name: "Connection", value: "close")
            await writeHead(status: response.statusCode, headers: headers)
            responseStarted = true

            let isEventStream = response.value(forHTTPHeaderField: "Content-Type")?
                .lowercased()
                .hasPrefix("text/event-stream") == true
            responseIsEventStream = isEventStream
            var usageTokens: Int64?
            var usageBody = Data()
            var usageBodyOverflowed = false
            usageBody.reserveCapacity(32 * 1_024)
            defer {
                if let usageTokens {
                    usageHandler?(GatewayTokenUsage(
                        routeID: request.routeID,
                        endpointID: request.endpointID,
                        tokens: usageTokens
                    ))
                }
            }
            var chunk = Data()
            chunk.reserveCapacity(16 * 1_024)
            for try await byte in bytes {
                try Task.checkCancellation()
                chunk.append(byte)
                if !isEventStream {
                    if usageBody.count < GatewayTokenUsageParser.maximumBufferedJSONBytes {
                        usageBody.append(byte)
                    } else {
                        usageBodyOverflowed = true
                    }
                }
                if chunk.count >= 16 * 1_024 || (isEventStream && Self.endsSSEEvent(chunk)) {
                    if isEventStream, let parsed = GatewayTokenUsageParser.tokens(inSSEEvent: chunk) {
                        usageTokens = max(usageTokens ?? 0, parsed)
                    }
                    await waitUntilWritable()
                    await writeBody(chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !isEventStream, !usageBodyOverflowed {
                usageTokens = GatewayTokenUsageParser.tokens(inJSON: usageBody)
            } else if isEventStream, !chunk.isEmpty,
                      let parsed = GatewayTokenUsageParser.tokens(inSSEEvent: chunk) {
                usageTokens = max(usageTokens ?? 0, parsed)
            }
            if !chunk.isEmpty { await writeBody(chunk) }
            await finish()
        } catch is CancellationError {
            // The local channel is already closing. Avoid scheduling another write
            // against its event loop while Gateway shutdown is in progress.
        } catch {
            if Task.isCancelled { return }
            if responseStarted {
                if responseIsEventStream {
                    // Once NIO has started an HTTP/1.1 response without a content
                    // length, closing the socket omits the terminating chunk and
                    // Chromium reports ERR_INCOMPLETE_CHUNKED_ENCODING. Finish the
                    // downstream framing so the client can handle an ended SSE at
                    // the protocol layer even when the upstream ended badly.
                    await finish()
                } else {
                    // Do not disguise a truncated JSON response as a complete one.
                    await close()
                }
            } else {
                await writeLocal(GatewayLocalResponse(
                    status: 502,
                    body: GatewayHTTPHandler.errorBody(code: "upstream_error", message: "Upstream request failed.")
                ))
            }
        }
    }

    private static func endsSSEEvent(_ data: Data) -> Bool {
        data.suffix(2).elementsEqual([0x0A, 0x0A])
            || data.suffix(4).elementsEqual([0x0D, 0x0A, 0x0D, 0x0A])
    }

    private func writeHead(status: Int, headers: HTTPHeaders) async {
        await onEventLoop {
            self.context.write(
                NIOAny(HTTPServerResponsePart.head(HTTPResponseHead(
                    version: .http1_1,
                    status: HTTPResponseStatus(statusCode: status),
                    headers: headers
                ))),
                promise: nil
            )
            self.context.flush()
        }
    }

    private func writeBody(_ data: Data) async {
        await onEventLoop {
            var buffer = self.context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            self.context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            self.context.flush()
        }
    }

    private func finish() async {
        await onEventLoop {
            self.context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                self.context.close(promise: nil)
            }
        }
    }

    private func close() async {
        await onEventLoop { self.context.close(promise: nil) }
    }

    private func waitUntilWritable() async {
        while !Task.isCancelled {
            let state = await channelState()
            if state.isWritable || !state.isActive { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func channelState() async -> (isWritable: Bool, isActive: Bool) {
        if context.eventLoop.inEventLoop {
            return (context.channel.isWritable, context.channel.isActive)
        }
        return (try? await context.eventLoop.submit {
            (self.context.channel.isWritable, self.context.channel.isActive)
        }.get()) ?? (false, false)
    }

    private func onEventLoop(_ operation: @escaping @Sendable () -> Void) async {
        if context.eventLoop.inEventLoop {
            operation()
        } else {
            _ = try? await context.eventLoop.submit(operation).get()
        }
    }
}

private final class UpstreamTaskCancellation: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let cancelImmediately = lock.withLock { () -> Bool in
            self.task = task
            return isCancelled
        }
        if cancelImmediately { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionTask? in
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
