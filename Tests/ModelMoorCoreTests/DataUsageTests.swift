import Foundation
import XCTest
import NIOCore
import NIOPosix
@testable import ModelMoorSystem

final class DataUsageTests: XCTestCase {
    func testHistorySeparatesPathsDirectionsAndTimeBucketsAcrossReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let first = UUID(), second = UUID(), tunnel = UUID()
        let store = DataUsageStore(directoryURL: directory)
        try await store.record(mappingID: first, tunnelID: tunnel, sent: 120, received: 350, at: now.addingTimeInterval(-12))
        try await store.record(mappingID: second, tunnelID: tunnel, sent: 600, received: 800, at: now.addingTimeInterval(-6))
        try await store.record(mappingID: first, tunnelID: tunnel, sent: 30, received: 70, at: now.addingTimeInterval(-2))
        let reloaded = DataUsageStore(directoryURL: directory)
        let all = try await reloaded.report(from: now.addingTimeInterval(-60), to: now, bucketInterval: 5)
        XCTAssertEqual(all.sent.totalBytes, 750)
        XCTAssertEqual(all.received.totalBytes, 1220)
        XCTAssertEqual(all.sent.series.reduce(0) { $0 + $1.bytes }, 750)
        XCTAssertEqual(all.sent.breakdowns.count, 2)
        let filtered = try await reloaded.report(from: now.addingTimeInterval(-10), to: now, bucketInterval: 5, mappingID: first)
        XCTAssertEqual(filtered.sent.totalBytes, 30)
        XCTAssertEqual(filtered.received.totalBytes, 70)
        XCTAssertEqual(filtered.sent.breakdowns.first?.tunnelID, tunnel)
        let content = try String(contentsOf: directory.appendingPathComponent("data-usage.jsonl"), encoding: .utf8)
        XCTAssertFalse(content.contains("tokens"))
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("data-usage.jsonl").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testTornFinalRecordRecoveryAndRetention() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(), mapping = UUID(), tunnel = UUID()
        let store = DataUsageStore(directoryURL: directory)
        try await store.record(mappingID: mapping, tunnelID: tunnel, sent: 1, received: 2, at: now.addingTimeInterval(-32 * 86400))
        try await store.record(mappingID: mapping, tunnelID: tunnel, sent: 3, received: 4, at: now)
        let file = directory.appendingPathComponent("data-usage.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"timestamp\":".utf8))
        try handle.close()
        let reloaded = DataUsageStore(directoryURL: directory)
        let result = try await reloaded.report(from: now.addingTimeInterval(-40 * 86400), to: now, bucketInterval: 86400)
        XCTAssertEqual(result.sent.totalBytes, 3)
        XCTAssertEqual(result.received.totalBytes, 4)
        try await reloaded.record(mappingID: mapping, tunnelID: tunnel, sent: 5, received: 6, at: now)
        let again = DataUsageStore(directoryURL: directory)
        let saved = try await again.report(from: now.addingTimeInterval(-60), to: now, bucketInterval: 5)
        XCTAssertEqual(saved.sent.totalBytes, 8)
    }

    func testInvalidRangesAreRejected() async throws {
        let store = DataUsageStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for interval in [0.0, Double.nan, Double.infinity, -1] {
            do {
                _ = try await store.report(from: Date().addingTimeInterval(-60), to: Date(), bucketInterval: interval)
                XCTFail("Accepted invalid interval")
            } catch DataUsageError.invalidRange {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testFailedWriteRemainsPendingAndRecoversWithoutDoubleCounting() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let blocked = parent.appendingPathComponent("blocked")
        try Data([0]).write(to: blocked)
        let store = DataUsageStore(directoryURL: blocked)
        let now = Date(), mapping = UUID(), tunnel = UUID()
        do {
            try await store.record(mappingID: mapping, tunnelID: tunnel, sent: 123, received: 456, at: now)
            XCTFail("Expected a storage failure")
        } catch {}
        try FileManager.default.removeItem(at: blocked)
        try await store.record(mappingID: mapping, tunnelID: tunnel, sent: 0, received: 0, at: now)
        let recovered = try await store.report(from: now.addingTimeInterval(-60), to: now, bucketInterval: 5)
        XCTAssertEqual(recovered.sent.totalBytes, 123)
        XCTAssertEqual(recovered.received.totalBytes, 456)
        let again = try await store.report(from: now.addingTimeInterval(-60), to: now, bucketInterval: 5)
        XCTAssertEqual(again.sent.totalBytes, 123)
    }

    func testSeparateRelaysKeepIndependentDirectionalCounters() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in channel.pipeline.addHandler(EchoAfterEOF(suffix: [9, 8, 7])) }
            .bind(host: "127.0.0.1", port: 0).get()
        let local = ForwardTrafficRelay(), remote = ForwardTrafficRelay()
        try await local.start(port: 0, destinationHost: "127.0.0.1", destinationPort: server.localAddress!.port!, inboundIsSent: true)
        try await remote.start(port: 0, destinationHost: "127.0.0.1", destinationPort: server.localAddress!.port!, inboundIsSent: false)
        _ = try await exchange(group: group, port: local.port, payload: [1, 2])
        _ = try await exchange(group: group, port: remote.port, payload: [3, 4, 5, 6])
        await local.stop()
        await remote.stop()
        let first = local.counter.drain(), second = remote.counter.drain()
        XCTAssertEqual(first.sent, 2)
        XCTAssertEqual(first.received, 5)
        XCTAssertEqual(second.sent, 7)
        XCTAssertEqual(second.received, 4)
        try await server.close().get()
        try await group.shutdownGracefully()
    }

    func testRelayPreservesLargePayloadAndHalfClosure() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in channel.pipeline.addHandler(EchoAfterEOF()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let relay = ForwardTrafficRelay()
        try await relay.start(port: 0, destinationHost: "127.0.0.1", destinationPort: server.localAddress!.port!, inboundIsSent: true)
        let payload = (0..<1_048_576).map { UInt8($0 % 251) }
        let result = try await exchange(group: group, port: relay.port, payload: payload)
        XCTAssertEqual(result, payload)
        await relay.stop()
        let counts = relay.counter.drain()
        XCTAssertEqual(counts.sent, Int64(payload.count))
        XCTAssertEqual(counts.received, Int64(payload.count))
        XCTAssertEqual(relay.counter.drain().sent, 0)
        try await server.close().get()
        try await group.shutdownGracefully()
    }

    func testReverseSOCKS4And5PreservePayloadAndCountBothDirections() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in channel.pipeline.addHandler(EchoAfterEOF()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let relay = ForwardTrafficRelay()
        try await relay.start(port: 0, destinationHost: "", destinationPort: 0, inboundIsSent: false, socks: true)
        let port = server.localAddress!.port!
        let high = UInt8(port / 256), low = UInt8(port % 256)
        let payload = Array("forwarded payload".utf8)
        let requests: [([UInt8], [UInt8])] = [
            ([5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, high, low], [5, 0, 5, 0, 0, 1, 0, 0, 0, 0, 0, 0]),
            ([5, 1, 0, 5, 1, 0, 3, 9] + Array("localhost".utf8) + [high, low], [5, 0, 5, 0, 0, 1, 0, 0, 0, 0, 0, 0]),
            ([4, 1, high, low, 127, 0, 0, 1, 0], [0, 90, 0, 0, 0, 0, 0, 0]),
            ([4, 1, high, low, 0, 0, 0, 1, 0] + Array("localhost".utf8) + [0], [0, 90, 0, 0, 0, 0, 0, 0])
        ]
        for (index, pair) in requests.enumerated() {
            let (request, response) = pair
            let result = try await exchange(group: group, port: relay.port, payload: request + payload, fragmented: index == 1)
            XCTAssertEqual(result, response + payload)
        }
        await relay.stop()
        let counts = relay.counter.drain()
        XCTAssertEqual(counts.received, Int64(requests.reduce(0) { $0 + $1.0.count + payload.count }))
        XCTAssertEqual(counts.sent, Int64(requests.reduce(0) { $0 + $1.1.count + payload.count }))
        try await server.close().get()
        try await group.shutdownGracefully()
    }

    func testRemoteSOCKSHonorsOpenSSHDestinationRestrictions() async throws {
        let policy = try RemoteForwardPolicy(effectiveConfiguration: "host example\npermitremoteopen example.org:443 [::1]:80 *:8443 localhost:*\n")
        XCTAssertTrue(policy.permits(host: "example.org", port: 443))
        XCTAssertTrue(policy.permits(host: "::1", port: 80))
        XCTAssertTrue(policy.permits(host: "anything", port: 8443))
        XCTAssertTrue(policy.permits(host: "localhost", port: 1234))
        XCTAssertFalse(policy.permits(host: "127.0.0.1", port: 1234))
        XCTAssertFalse(policy.permits(host: "example.org", port: 80))
        XCTAssertThrowsError(try RemoteForwardPolicy(effectiveConfiguration: "host example"))
        let denied = try RemoteForwardPolicy(effectiveConfiguration: "permitremoteopen none")
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let relay = ForwardTrafficRelay()
        try await relay.start(port: 0, destinationHost: "", destinationPort: 0, inboundIsSent: false, socks: true, remotePolicy: denied)
        let result = try await exchange(group: group, port: relay.port, payload: [5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, 0, 80])
        XCTAssertEqual(result, [5, 0, 5, 2, 0, 1, 0, 0, 0, 0, 0, 0])
        await relay.stop()
        try await group.shutdownGracefully()
    }

    func testReverseSOCKSRejectsUnsupportedAuthenticationAndCommands() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let relay = ForwardTrafficRelay()
        try await relay.start(port: 0, destinationHost: "", destinationPort: 0, inboundIsSent: false, socks: true)
        let authentication = try await exchange(group: group, port: relay.port, payload: [5, 1, 2])
        XCTAssertEqual(authentication, [5, 255])
        let command = try await exchange(group: group, port: relay.port, payload: [5, 1, 0, 5, 3, 0, 1, 127, 0, 0, 1, 0, 80])
        XCTAssertEqual(command, [5, 0, 5, 7, 0, 1, 0, 0, 0, 0, 0, 0])
        await relay.stop()
        try await group.shutdownGracefully()
    }

    private func exchange(group: EventLoopGroup, port: Int, payload: [UInt8], fragmented: Bool = false) async throws -> [UInt8] {
        let loop = group.next()
        let promise = loop.makePromise(of: [UInt8].self)
        let timeout = loop.scheduleTask(in: .seconds(10)) { promise.fail(TestFailure.timeout) }
        let client = try await ClientBootstrap(group: loop)
            .channelInitializer { channel in channel.pipeline.addHandler(CollectResponse(promise: promise)) }
            .connect(host: "127.0.0.1", port: port).get()
        let chunkSize = fragmented ? 1 : payload.count
        for offset in stride(from: 0, to: payload.count, by: chunkSize) {
            var buffer = client.allocator.buffer(capacity: chunkSize)
            buffer.writeBytes(payload[offset..<min(offset + chunkSize, payload.count)])
            try await client.writeAndFlush(buffer).get()
            if fragmented { try await Task.sleep(for: .milliseconds(2)) }
        }
        try await client.close(mode: .output).get()
        do {
            let result = try await promise.futureResult.get()
            timeout.cancel()
            try? await client.close().get()
            return result
        } catch {
            timeout.cancel()
            try? await client.close().get()
            throw error
        }
    }
}

private enum TestFailure: Error { case timeout }

private final class EchoAfterEOF: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var bytes: [UInt8] = []
    private let suffix: [UInt8]
    init(suffix: [UInt8] = []) { self.suffix = suffix }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bytes.append(contentsOf: unwrapInboundIn(data).readableBytesView)
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            var buffer = context.channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes + suffix)
            let channel = context.channel
            channel.writeAndFlush(buffer).whenComplete { _ in channel.close(promise: nil) }
        } else { context.fireUserInboundEventTriggered(event) }
    }
}

private final class CollectResponse: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var bytes: [UInt8] = []
    let promise: EventLoopPromise<[UInt8]>
    init(promise: EventLoopPromise<[UInt8]>) { self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bytes.append(contentsOf: unwrapInboundIn(data).readableBytesView)
    }
    func channelInactive(context: ChannelHandlerContext) { promise.succeed(bytes) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { promise.fail(error); context.close(promise: nil) }
}
