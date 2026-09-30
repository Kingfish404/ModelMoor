import Foundation
import NIOCore
import NIOPosix

/// Reverse dynamic forwarding terminates SOCKS on this machine, just as ssh -R
/// does. Only TCP CONNECT is supported (SOCKS4/4a and unauthenticated SOCKS5).
final class ForwardSOCKSHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var buffer: ByteBuffer?
    private var greeted = false
    private var connecting = false
    private var inputClosed = false
    private let policy: RemoteForwardPolicy?
    private let counter: ForwardTrafficCounter
    private let track: @Sendable (Channel) -> Void

    init(counter: ForwardTrafficCounter, policy: RemoteForwardPolicy?, track: @escaping @Sendable (Channel) -> Void) {
        self.policy = policy
        self.counter = counter
        self.track = track
    }

    func channelActive(context: ChannelHandlerContext) {
        context.read()
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            inputClosed = true
            if !connecting { context.close(promise: nil) }
        } else { context.fireUserInboundEventTriggered(event) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if buffer == nil { buffer = incoming }
        else { buffer?.writeBuffer(&incoming) }
        guard !connecting else { return }
        guard let buffer, buffer.readableBytes <= 65_536 else {
            context.close(promise: nil)
            return
        }
        let bytes = Array(buffer.readableBytesView)
        guard let version = bytes.first else { context.read(); return }
        if version == 5 {
            if !greeted {
                guard bytes.count >= 2, bytes.count >= 2 + Int(bytes[1]) else { context.read(); return }
                let length = 2 + Int(bytes[1])
                guard bytes[2..<length].contains(0) else {
                    reply([5, 255], channel: context.channel, close: true)
                    return
                }
                consume(length)
                greeted = true
                reply([5, 0], channel: context.channel)
                if self.buffer?.readableBytes ?? 0 > 0 {
                    channelRead(context: context, data: NIOAny(context.channel.allocator.buffer(capacity: 0)))
                } else { context.read() }
                return
            }
            guard bytes.count >= 4 else { context.read(); return }
            guard bytes[1] == 1, bytes[2] == 0 else { fail(version: 5, channel: context.channel, code: 7); return }
            let host: String
            let addressEnd: Int
            switch bytes[3] {
            case 1:
                guard bytes.count >= 10 else { context.read(); return }
                host = bytes[4..<8].map(String.init).joined(separator: ".")
                addressEnd = 8
            case 3:
                guard bytes.count >= 5, bytes.count >= 7 + Int(bytes[4]) else { context.read(); return }
                addressEnd = 5 + Int(bytes[4])
                guard bytes[4] > 0, let name = String(bytes: bytes[5..<addressEnd], encoding: .utf8), !name.contains("\0") else {
                    fail(version: 5, channel: context.channel, code: 8); return
                }
                host = name
            case 4:
                guard bytes.count >= 22 else { context.read(); return }
                let expanded = stride(from: 4, to: 20, by: 2).map {
                    String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16)
                }.joined(separator: ":")
                host = (try? SocketAddress(ipAddress: expanded, port: 0))?.ipAddress ?? expanded
                addressEnd = 20
            default:
                fail(version: 5, channel: context.channel, code: 8); return
            }
            let port = Int(bytes[addressEnd]) * 256 + Int(bytes[addressEnd + 1])
            consume(addressEnd + 2)
            connect(host: host, port: port, version: 5, channel: context.channel)
        } else if version == 4, !greeted {
            guard bytes.count >= 9 else { context.read(); return }
            guard bytes[1] == 1 else { fail(version: 4, channel: context.channel); return }
            guard let userEnd = bytes[8...].firstIndex(of: 0) else { context.read(); return }
            let host: String
            var end = userEnd + 1
            if bytes[4..<7].allSatisfy({ $0 == 0 }), bytes[7] != 0 {
                guard end < bytes.count, let hostEnd = bytes[end...].firstIndex(of: 0) else { context.read(); return }
                guard hostEnd > end, let name = String(bytes: bytes[end..<hostEnd], encoding: .utf8) else {
                    fail(version: 4, channel: context.channel); return
                }
                host = name
                end = hostEnd + 1
            } else {
                host = bytes[4..<8].map(String.init).joined(separator: ".")
            }
            let port = Int(bytes[2]) * 256 + Int(bytes[3])
            consume(end)
            connect(host: host, port: port, version: 4, channel: context.channel)
        } else {
            context.close(promise: nil)
        }
    }

    private func consume(_ count: Int) {
        buffer?.moveReaderIndex(forwardBy: count)
        counter.add(count, sent: false)
    }

    private func reply(_ bytes: [UInt8], channel: Channel, close: Bool = false) {
        var response = channel.allocator.buffer(capacity: bytes.count)
        response.writeBytes(bytes)
        channel.writeAndFlush(response).whenComplete { [counter] result in
            if case .success = result { counter.add(bytes.count, sent: true) }
            if close { channel.close(promise: nil) }
        }
    }

    private func fail(version: UInt8, channel: Channel, code: UInt8 = 5) {
        reply(version == 5 ? [5, code, 0, 1, 0, 0, 0, 0, 0, 0] : [0, 91, 0, 0, 0, 0, 0, 0], channel: channel, close: true)
    }

    private func connect(host: String, port: Int, version: UInt8, channel: Channel) {
        guard port > 0 else { fail(version: version, channel: channel); return }
        guard policy?.permits(host: host, port: port) != false else { fail(version: version, channel: channel, code: 2); return }
        connecting = true
        ClientBootstrap(group: channel.eventLoop)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .connectTimeout(.seconds(10))
            .connect(host: host, port: port)
            .flatMap { [self] peer -> EventLoopFuture<Void> in
                track(peer)
                guard channel.isActive else {
                    peer.close(promise: nil)
                    return channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
                }
                return peer.pipeline.addHandler(TrafficPipe(peer: channel, counter: counter, sent: true))
                    .flatMap {
                        channel.pipeline.addHandler(TrafficPipe(peer: peer, counter: self.counter, sent: false), position: .after(self))
                    }.flatMap {
                        self.reply(version == 5 ? [5, 0, 0, 1, 0, 0, 0, 0, 0, 0] : [0, 90, 0, 0, 0, 0, 0, 0], channel: channel)
                        if let buffered = self.buffer, buffered.readableBytes > 0 {
                            // Deliver any payload pipelined with the CONNECT request.
                            do {
                                let context = try channel.pipeline.syncOperations.context(handler: self)
                                context.fireChannelRead(NIOAny(buffered))
                                if self.inputClosed { context.fireUserInboundEventTriggered(ChannelEvent.inputClosed) }
                            } catch {
                                peer.close(promise: nil)
                                return channel.eventLoop.makeFailedFuture(error)
                            }
                        }
                        if self.inputClosed, self.buffer?.readableBytes == 0 { peer.close(mode: .output, promise: nil) }
                        return channel.pipeline.removeHandler(self)
                    }.map {
                        peer.read()
                        channel.read()
                    }
            }.whenFailure { [self] _ in fail(version: version, channel: channel) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
