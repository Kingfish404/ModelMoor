import Foundation
import NIOCore
import NIOPosix

/// One loopback listener per mapping. Auto-read is disabled until the peer is
/// connected; each read is resumed only after the preceding write completes.
final class ForwardTrafficRelay: @unchecked Sendable {
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let counter = ForwardTrafficCounter()
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var stopped = false
    private var listener: Channel?
    var port: Int { listener?.localAddress?.port ?? 0 }

    func start(port: Int, destinationHost: String, destinationPort: Int, inboundIsSent: Bool, socks: Bool = false, remotePolicy: RemoteForwardPolicy? = nil) async throws {
        let listener = try await ServerBootstrap(group: Self.group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { [self] channel in
                track(channel)
                if socks {
                    return channel.pipeline.addHandler(ForwardSOCKSHandler(counter: self.counter, policy: remotePolicy) { peer in self.track(peer) })
                        .map { channel.read() }
                }
                return self.connect(channel, host: destinationHost, port: destinationPort, inboundIsSent: inboundIsSent)

            }
            .bind(host: "127.0.0.1", port: port).get()
        self.listener = listener
        track(listener)
    }

    private func connect(_ channel: Channel, host: String, port: Int, inboundIsSent: Bool) -> EventLoopFuture<Void> {
        ClientBootstrap(group: channel.eventLoop)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .connectTimeout(.seconds(10))
            .connect(host: host, port: port)
            .flatMap { peer in
                self.track(peer)
                return peer.pipeline.addHandler(TrafficPipe(peer: channel, counter: self.counter, sent: !inboundIsSent))
                    .flatMap {
                        channel.pipeline.addHandler(TrafficPipe(peer: peer, counter: self.counter, sent: inboundIsSent))
                    }.map {
                        peer.read()
                        channel.read()
                    }
            }.flatMapError { error in
                channel.close(promise: nil)
                return channel.eventLoop.makeFailedFuture(error)
            }
    }

    private func track(_ channel: Channel) {
        let shouldClose = lock.withLock {
            if stopped { return true }
            channels[ObjectIdentifier(channel)] = channel
            return false
        }
        if shouldClose { channel.close(promise: nil) }
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.channels.removeValue(forKey: ObjectIdentifier(channel)) }
        }
    }

    func stop() async {
        let current = lock.withLock {
            stopped = true
            return Array(channels.values)
        }
        for channel in current { try? await channel.close().get() }
    }
}

final class TrafficPipe: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let peer: Channel
    let counter: ForwardTrafficCounter
    let sent: Bool
    private var pendingWrites = 0
    private var inputClosed = false
    private var inactive = false

    init(peer: Channel, counter: ForwardTrafficCounter, sent: Bool) {
        self.peer = peer
        self.counter = counter
        self.sent = sent
    }

    func channelActive(context: ChannelHandlerContext) {
        context.read()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        let count = buffer.readableBytes
        let channel = context.channel
        pendingWrites += 1
        peer.writeAndFlush(buffer).whenComplete { [self] result in
            pendingWrites -= 1
            switch result {
            case .success:
                counter.add(count, sent: sent)
                if inactive {
                    if pendingWrites == 0 { peer.close(promise: nil) }
                } else if inputClosed {
                    if pendingWrites == 0 { peer.close(mode: .output, promise: nil) }
                } else { channel.read() }
            case .failure:
                channel.close(promise: nil)
                peer.close(promise: nil)
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            inputClosed = true
            if pendingWrites == 0 { peer.close(mode: .output, promise: nil) }
        } else { context.fireUserInboundEventTriggered(event) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        inactive = true
        if pendingWrites == 0 { peer.close(promise: nil) }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        peer.close(promise: nil)
    }
}
