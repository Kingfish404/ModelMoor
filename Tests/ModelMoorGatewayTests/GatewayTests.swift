import Darwin
import Foundation
import ModelMoorCore
@testable import ModelMoorGateway
import XCTest

final class GatewayTests: XCTestCase {
    func testLoopbackListenerServesAuthenticatedModelList() async throws {
        let port = try unusedLoopbackPort()
        let fixture = makeFixture()
        var configuration = fixture.snapshot.configuration
        configuration.gateway = GatewayConfiguration(enabled: true, listenPort: port)
        let service = GatewayService()
        try await service.start(snapshot: GatewaySnapshot(
            configuration: configuration,
            gatewayAPIKeys: fixture.snapshot.gatewayAPIKeys,
            endpointSecrets: fixture.snapshot.endpointSecrets
        ))
        defer { Task { await service.stop() } }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        request.setValue("Bearer local-token", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"fast\""))
        XCTAssertEqual(service.state, .running(port: port))
        await service.stop()
        XCTAssertEqual(service.state, .stopped)
    }

    func testGatewayStreamsSSEBeforeUpstreamCompletesAndRewritesCredential() async throws {
        let upstream = try LoopbackSSEFixture()
        defer { upstream.allowSecondEvent() }
        let gatewayPort = try unusedLoopbackPort()
        let mapping = PortMappingConfiguration(listenPort: upstream.port, destinationPort: 8_888)
        let tunnel = TunnelConfiguration(name: "Remote", sshHost: "remote", mappings: [mapping])
        let endpoint = APIEndpointConfiguration(
            name: "Remote API",
            source: .sshMapping(mappingID: mapping.id, originScheme: .http),
            authentication: .bearer
        )
        let route = ModelRouteConfiguration(
            publicModel: "fast",
            endpointID: endpoint.id,
            upstreamModel: "upstream-fast"
        )
        let configuration = ModelMoorConfiguration(
            tunnels: [tunnel],
            endpoints: [endpoint],
            routes: [route],
            gateway: GatewayConfiguration(enabled: true, listenPort: gatewayPort)
        )
        let usage = TestUsageRecorder()
        let service = GatewayService(usageHandler: usage.record)
        try await service.start(snapshot: GatewaySnapshot(
            configuration: configuration,
            gatewayToken: "local-token",
            endpointSecrets: [endpoint.id: "upstream-secret"],
            availableMappingIDs: [mapping.id]
        ))
        defer { Task { await service.stop() } }

        let firstEventAtClient = TestSignal()
        let client = Task.detached {
            try sendStreamingGatewayRequest(port: gatewayPort, firstEventAtClient: firstEventAtClient)
        }
        let arrivedBeforeCompletion = await Task.detached {
            firstEventAtClient.wait(seconds: 2)
        }.value
        XCTAssertTrue(arrivedBeforeCompletion, "The first SSE event should reach the client while upstream is still open")
        XCTAssertFalse(upstream.didSendSecondEvent)

        upstream.allowSecondEvent()
        let response = try await client.value
        XCTAssertLessThan(
            try XCTUnwrap(response.range(of: "data: one\n\n")?.lowerBound),
            try XCTUnwrap(response.range(of: "data: two\n\n")?.lowerBound)
        )
        let upstreamRequest = upstream.requestText
        XCTAssertTrue(upstreamRequest.contains("Authorization: Bearer upstream-secret"))
        XCTAssertFalse(upstreamRequest.contains("Bearer local-token"))
        XCTAssertTrue(upstreamRequest.contains("upstream-fast"))
        XCTAssertEqual(usage.values.map(\.tokens), [20])
        XCTAssertEqual(usage.values.first?.routeID, route.id)
        XCTAssertEqual(usage.values.first?.endpointID, endpoint.id)
        await service.stop()
    }

    func testGatewayTerminatesChunkedResponseWhenUpstreamSSEBreaksMidStream() async throws {
        let upstream = try LoopbackTruncatedSSEFixture()
        let gatewayPort = try unusedLoopbackPort()
        let configured = gatewayFixture(gatewayPort: gatewayPort, upstreamPort: upstream.port)
        let service = GatewayService()
        try await service.start(snapshot: configured.snapshot)
        defer { Task { await service.stop() } }

        let response = try sendRawStreamingGatewayRequest(port: gatewayPort)

        XCTAssertTrue(response.lowercased().contains("transfer-encoding: chunked"))
        XCTAssertTrue(
            response.hasSuffix("\r\n0\r\n\r\n"),
            "A started chunked response must still emit its terminating chunk when the upstream stream fails"
        )
        await service.stop()
    }

    func testGatewayPassesThroughOrdinaryJSONAndUpstreamErrorsWithoutRetry() async throws {
        for fixtureResponse in [
            HTTPFixtureResponse(
                statusLine: "200 OK",
                contentType: "application/json",
                body: #"{"id":"chatcmpl-1","choices":[{"message":{"content":"hello"}}],"usage":{"prompt_tokens":31,"completion_tokens":11,"total_tokens":42}}"#
            ),
            HTTPFixtureResponse(
                statusLine: "429 Too Many Requests",
                contentType: "application/json; charset=utf-8",
                body: #"{"error":{"message":"quota exhausted","type":"rate_limit_error"}}"#
            )
        ] {
            let upstream = try LoopbackHTTPFixture(response: fixtureResponse)
            let gatewayPort = try unusedLoopbackPort()
            let configured = gatewayFixture(gatewayPort: gatewayPort, upstreamPort: upstream.port)
            let usage = TestUsageRecorder()
            let service = GatewayService(usageHandler: usage.record)
            try await service.start(snapshot: configured.snapshot)

            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(gatewayPort)/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"model":"public-model","messages":[]}"#.utf8)
            request.setValue("Bearer local-token", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (body, response) = try await URLSession.shared.data(for: request)

            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, fixtureResponse.statusCode)
            XCTAssertEqual(String(decoding: body, as: UTF8.self), fixtureResponse.body)
            XCTAssertEqual(response.mimeType, "application/json")
            XCTAssertEqual(upstream.requestCount, 1, "The Gateway must not retry inference requests")
            XCTAssertTrue(upstream.requestText.contains("Authorization: Bearer upstream-secret"))
            XCTAssertFalse(upstream.requestText.contains("Bearer local-token"))
            XCTAssertTrue(upstream.requestText.contains("upstream-model"))
            XCTAssertEqual(usage.values.map(\.tokens), fixtureResponse.statusCode == 200 ? [42] : [])
            await service.stop()
        }
    }

    func testUsageParserSupportsChatResponsesAndResponsesAPIShapes() {
        XCTAssertEqual(
            GatewayTokenUsageParser.tokens(inJSON: Data(#"{"usage":{"prompt_tokens":12,"completion_tokens":8}}"#.utf8)),
            20
        )
        XCTAssertEqual(
            GatewayTokenUsageParser.tokens(inJSON: Data(#"{"response":{"usage":{"input_tokens":7,"output_tokens":5,"total_tokens":12}}}"#.utf8)),
            12
        )
        XCTAssertEqual(
            GatewayTokenUsageParser.tokens(inSSEEvent: Data("data: {\"usage\":{\"total_tokens\":33}}\n\n".utf8)),
            33
        )
        XCTAssertNil(GatewayTokenUsageParser.tokens(inSSEEvent: Data("data: [DONE]\n\n".utf8)))
    }

    func testGatewayPortConflictAndStopReleaseTheListener() async throws {
        let port = try unusedLoopbackPort()
        let fixture = makeFixture()
        var configuration = fixture.snapshot.configuration
        configuration.gateway = GatewayConfiguration(enabled: true, listenPort: port)
        let snapshot = GatewaySnapshot(
            configuration: configuration,
            gatewayToken: "local-token",
            endpointSecrets: fixture.snapshot.endpointSecrets
        )
        let first = GatewayService()
        let second = GatewayService()
        try await first.start(snapshot: snapshot)
        do {
            try await second.start(snapshot: snapshot)
            XCTFail("A second Gateway must not bind an occupied port")
        } catch {
            guard case .failed = second.state else { return XCTFail("Expected failed Gateway state") }
        }

        await first.stop()
        XCTAssertEqual(first.state, .stopped)
        try await second.start(snapshot: snapshot)
        XCTAssertEqual(second.state, .running(port: port))
        await second.stop()
    }

    func testClientDisconnectCancelsTheUpstreamRequest() async throws {
        let upstream = try LoopbackCancellationFixture()
        let cancellation = TestSignal()
        let gatewayPort = try unusedLoopbackPort()
        let configured = gatewayFixture(gatewayPort: gatewayPort, upstreamPort: upstream.port)
        let service = GatewayService(upstreamCancellationObserver: cancellation.signal)
        try await service.start(snapshot: configured.snapshot)

        try sendGatewayRequestAndDisconnectAfterFirstEvent(port: gatewayPort)
        let cancelledInTime = cancellation.wait(seconds: 1)
        await service.stop()
        upstream.finish()
        XCTAssertTrue(
            cancelledInTime,
            "Closing the local client should cancel the upstream request within one second"
        )
    }

    func testRequestValidationRejectsUnsupportedContentInvalidJSONAndOversizedBodies() {
        let router = GatewayRequestRouter(snapshot: makeFixture().snapshot)
        let cases: [(GatewayRequest, Int)] = [
            (
                GatewayRequest(
                    method: "POST",
                    uri: "/v1/chat/completions",
                    headers: ["Authorization": "Bearer local-token", "Content-Type": "text/plain"],
                    body: Data(#"{"model":"fast"}"#.utf8)
                ),
                415
            ),
            (
                GatewayRequest(
                    method: "POST",
                    uri: "/v1/chat/completions",
                    headers: ["Authorization": "Bearer local-token", "Content-Type": "application/json"],
                    body: Data("{".utf8)
                ),
                400
            ),
            (
                GatewayRequest(
                    method: "POST",
                    uri: "/v1/chat/completions",
                    headers: ["Authorization": "Bearer local-token", "Content-Type": "application/json"],
                    body: Data(count: GatewayRequestRouter.maximumBodyBytes + 1)
                ),
                413
            )
        ]

        for (request, expectedStatus) in cases {
            guard case let .local(response) = router.route(request) else {
                XCTFail("Invalid input must not reach upstream")
                continue
            }
            XCTAssertEqual(response.status, expectedStatus)
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: response.body))
        }
    }

    func testConcurrencyLimitRejectsRatherThanQueuesAnAdditionalRequest() async throws {
        let upstream = try LoopbackCancellationFixture()
        let gatewayPort = try unusedLoopbackPort()
        let configured = gatewayFixture(gatewayPort: gatewayPort, upstreamPort: upstream.port)
        let service = GatewayService(maximumActiveRequests: 1)
        try await service.start(snapshot: configured.snapshot)

        let first = Task { try await URLSession.shared.data(for: gatewayURLRequest(port: gatewayPort)) }
        XCTAssertTrue(upstream.waitUntilStreaming(seconds: 1))
        let (body, response) = try await URLSession.shared.data(for: gatewayURLRequest(port: gatewayPort))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("gateway_busy"))

        first.cancel()
        await service.stop()
        upstream.finish()
        _ = await first.result
    }

    func testModelsAreStableAndUsePublicAliases() throws {
        let fixture = makeFixture()
        let router = GatewayRequestRouter(snapshot: fixture.snapshot)
        let decision = router.route(GatewayRequest(
            method: "GET",
            uri: "/v1/models",
            headers: ["Authorization": "Bearer local-token"],
            body: Data()
        ))
        guard case let .local(response) = decision else { return XCTFail("Expected local response") }
        XCTAssertEqual(response.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let models = try XCTUnwrap(json["data"] as? [[String: String]])
        XCTAssertEqual(models.map { $0["id"] }, ["fast"])
    }

    func testRouterRebuildsIndexesWhenSnapshotChanges() throws {
        var router = GatewayRequestRouter(snapshot: makeFixture().snapshot)
        var updatedSnapshot = router.snapshot
        updatedSnapshot.configuration.routes[0].publicModel = "precise"
        router.snapshot = updatedSnapshot

        let decision = router.route(GatewayRequest(
            method: "GET",
            uri: "/v1/models",
            headers: ["Authorization": "Bearer local-token"],
            body: Data()
        ))
        guard case let .local(response) = decision else { return XCTFail("Expected local response") }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let models = try XCTUnwrap(json["data"] as? [[String: String]])
        XCTAssertEqual(models.map { $0["id"] }, ["precise"])
    }

    func testRouteRewritesModelAndIsolatesUpstreamCredential() throws {
        let fixture = makeFixture()
        let router = GatewayRequestRouter(snapshot: fixture.snapshot)
        let decision = router.route(GatewayRequest(
            method: "POST",
            uri: "/v1/chat/completions?beta=true",
            headers: [
                "Authorization": "Bearer local-token",
                "Content-Type": "application/json",
                "Host": "127.0.0.1:17777",
                "Connection": "keep-alive"
            ],
            body: Data("{\"model\":\"fast\",\"messages\":[]}".utf8)
        ))
        guard case let .upstream(prepared) = decision else { return XCTFail("Expected upstream request") }
        XCTAssertEqual(prepared.urlRequest.url?.absoluteString, "https://api.deepseek.com/chat/completions?beta=true")
        XCTAssertEqual(prepared.urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer upstream-secret")
        XCTAssertNil(prepared.urlRequest.value(forHTTPHeaderField: "Connection"))
        let body = try XCTUnwrap(prepared.urlRequest.httpBody)
        XCTAssertEqual(prepared.urlRequest.value(forHTTPHeaderField: "Content-Length"), String(body.count))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek-v4-flash")
    }

    func testManagedSubscriptionRouteUsesOnlyTheLoopbackSidecar() throws {
        var configuration = ModelMoorConfiguration(
            routes: [ModelRouteConfiguration(
                publicModel: "chatgpt-codex",
                endpointID: CLIProxyConfiguration.defaultEndpointID,
                upstreamModel: "gpt-5.4"
            )],
            gateway: GatewayConfiguration(enabled: true),
            cliProxy: CLIProxyConfiguration(enabled: true, listenPort: 18_317)
        )
        configuration.reconcileManagedCLIProxyEndpoint()
        let router = GatewayRequestRouter(snapshot: GatewaySnapshot(
            configuration: try configuration.validated(),
            gatewayToken: "local-token",
            endpointSecrets: [configuration.cliProxy.endpointID: "sidecar-key"]
        ))

        let decision = router.route(GatewayRequest(
            method: "POST",
            uri: "/v1/responses",
            headers: [
                "Authorization": "Bearer local-token",
                "Content-Type": "application/json"
            ],
            body: Data(#"{"model":"chatgpt-codex","input":"hello"}"#.utf8)
        ))

        guard case let .upstream(prepared) = decision else { return XCTFail("Expected sidecar request") }
        XCTAssertEqual(prepared.urlRequest.url?.absoluteString, "http://127.0.0.1:18317/v1/responses")
        XCTAssertEqual(prepared.urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer sidecar-key")
        let body = try XCTUnwrap(prepared.urlRequest.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-5.4")
    }

    func testAuthenticationAndUnknownModelNeverReachUpstream() {
        let router = GatewayRequestRouter(snapshot: makeFixture().snapshot)
        for request in [
            GatewayRequest(method: "GET", uri: "/v1/models", headers: [:], body: Data()),
            GatewayRequest(
                method: "POST",
                uri: "/v1/chat/completions",
                headers: ["Authorization": "Bearer local-token", "Content-Type": "application/json"],
                body: Data("{\"model\":\"missing\"}".utf8)
            )
        ] {
            guard case let .local(response) = router.route(request) else {
                XCTFail("Request must not reach upstream")
                continue
            }
            XCTAssertTrue([401, 404].contains(response.status))
        }
    }

    func testAnyEnabledAPIKeyAuthenticates() throws {
        let fixture = makeFixture()
        let router = GatewayRequestRouter(snapshot: GatewaySnapshot(
            configuration: fixture.snapshot.configuration,
            gatewayAPIKeys: ["desktop-key", "automation-key"],
            endpointSecrets: fixture.snapshot.endpointSecrets
        ))

        for key in ["desktop-key", "automation-key"] {
            let decision = router.route(GatewayRequest(
                method: "GET",
                uri: "/v1/models",
                headers: ["Authorization": "Bearer \(key)"],
                body: Data()
            ))
            guard case let .local(response) = decision else { return XCTFail("Expected local response") }
            XCTAssertEqual(response.status, 200)
        }

        let rejected = router.route(GatewayRequest(
            method: "GET",
            uri: "/v1/models",
            headers: ["Authorization": "Bearer disabled-key"],
            body: Data()
        ))
        guard case let .local(response) = rejected else { return XCTFail("Expected local response") }
        XCTAssertEqual(response.status, 401)
    }

    func testAuthenticationCanBeDisabledForLoopbackClients() throws {
        let fixture = makeFixture()
        var configuration = fixture.snapshot.configuration
        configuration.gateway.requiresAPIKey = false
        let router = GatewayRequestRouter(snapshot: GatewaySnapshot(
            configuration: configuration,
            gatewayAPIKeys: [],
            endpointSecrets: fixture.snapshot.endpointSecrets
        ))
        let decision = router.route(GatewayRequest(
            method: "GET",
            uri: "/v1/models",
            headers: [:],
            body: Data()
        ))
        guard case let .local(response) = decision else { return XCTFail("Expected local response") }
        XCTAssertEqual(response.status, 200)
    }

    func testMissingEndpointCredentialIsNotReportedAsRateLimit() throws {
        let fixture = makeFixture()
        let router = GatewayRequestRouter(snapshot: GatewaySnapshot(
            configuration: fixture.snapshot.configuration,
            gatewayAPIKeys: fixture.snapshot.gatewayAPIKeys,
            endpointSecrets: [:]
        ))
        let decision = router.route(GatewayRequest(
            method: "POST",
            uri: "/v1/chat/completions",
            headers: [
                "Authorization": "Bearer local-token",
                "Content-Type": "application/json"
            ],
            body: Data("{\"model\":\"fast\",\"messages\":[]}".utf8)
        ))

        guard case let .local(response) = decision else { return XCTFail("Expected local failure") }
        XCTAssertEqual(response.status, 424)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let error = try XCTUnwrap(json["error"] as? [String: String])
        XCTAssertEqual(error["code"], "credential_unavailable")
    }

    func testSSHRouteRequiresAvailableTransport() {
        let mapping = PortMappingConfiguration()
        let tunnel = TunnelConfiguration(name: "Remote", sshHost: "remote", mappings: [mapping])
        let endpoint = APIEndpointConfiguration(
            name: "Remote API",
            source: .sshMapping(mappingID: mapping.id, originScheme: .http),
            authentication: .none
        )
        let route = ModelRouteConfiguration(publicModel: "remote", endpointID: endpoint.id, upstreamModel: "qwen")
        let configuration = ModelMoorConfiguration(tunnels: [tunnel], endpoints: [endpoint], routes: [route])
        let router = GatewayRequestRouter(snapshot: GatewaySnapshot(
            configuration: configuration,
            gatewayToken: "token",
            availableMappingIDs: []
        ))
        let decision = router.route(GatewayRequest(
            method: "POST",
            uri: "/v1/chat/completions",
            headers: ["Authorization": "Bearer token", "Content-Type": "application/json"],
            body: Data("{\"model\":\"remote\"}".utf8)
        ))
        guard case let .local(response) = decision else { return XCTFail("Expected local failure") }
        XCTAssertEqual(response.status, 503)
    }

    private func makeFixture() -> (snapshot: GatewaySnapshot, endpoint: APIEndpointConfiguration) {
        let endpoint = APIEndpointConfiguration.deepSeek()
        let route = ModelRouteConfiguration(
            publicModel: "fast",
            endpointID: endpoint.id,
            upstreamModel: "deepseek-v4-flash"
        )
        return (
            GatewaySnapshot(
                configuration: ModelMoorConfiguration(endpoints: [endpoint], routes: [route]),
                gatewayToken: "local-token",
                endpointSecrets: [endpoint.id: "upstream-secret"]
            ),
            endpoint
        )
    }

    private func gatewayFixture(
        gatewayPort: Int,
        upstreamPort: Int
    ) -> (snapshot: GatewaySnapshot, endpoint: APIEndpointConfiguration) {
        let mapping = PortMappingConfiguration(listenPort: upstreamPort, destinationPort: 8_888)
        let tunnel = TunnelConfiguration(name: "Remote", sshHost: "remote", mappings: [mapping])
        let endpoint = APIEndpointConfiguration(
            name: "Remote API",
            source: .sshMapping(mappingID: mapping.id, originScheme: .http),
            authentication: .bearer
        )
        let route = ModelRouteConfiguration(
            publicModel: "public-model",
            endpointID: endpoint.id,
            upstreamModel: "upstream-model"
        )
        let configuration = ModelMoorConfiguration(
            tunnels: [tunnel],
            endpoints: [endpoint],
            routes: [route],
            gateway: GatewayConfiguration(enabled: true, listenPort: gatewayPort)
        )
        return (
            GatewaySnapshot(
                configuration: configuration,
                gatewayToken: "local-token",
                endpointSecrets: [endpoint.id: "upstream-secret"],
                availableMappingIDs: [mapping.id]
            ),
            endpoint
        )
    }

    private func unusedLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw POSIXError(.EIO) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

private final class TestSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func signal() { semaphore.signal() }
    func wait(seconds: Double) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }
}

private final class TestUsageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [GatewayTokenUsage] = []

    var values: [GatewayTokenUsage] { lock.withLock { storedValues } }
    func record(_ value: GatewayTokenUsage) { lock.withLock { storedValues.append(value) } }
}

private struct HTTPFixtureResponse {
    let statusLine: String
    let contentType: String
    let body: String

    var statusCode: Int { Int(statusLine.split(separator: " ").first ?? "0") ?? 0 }
}

private final class LoopbackHTTPFixture: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let response: HTTPFixtureResponse
    private let lock = NSLock()
    private var storedRequest = ""
    private var storedRequestCount = 0

    var requestText: String { lock.withLock { storedRequest } }
    var requestCount: Int { lock.withLock { storedRequestCount } }

    init(response: HTTPFixtureResponse) throws {
        self.response = response
        let listening = try makeLoopbackListener()
        listener = listening.descriptor
        port = listening.port
        start()
    }

    deinit { close(listener) }

    private func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            let request = receiveHTTPRequest(client)
            lock.withLock {
                storedRequest = request
                storedRequestCount += 1
            }
            sendAll(
                client,
                "HTTP/1.1 \(response.statusLine)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.utf8.count)\r\nConnection: close\r\n\r\n\(response.body)"
            )
        }
    }
}

private final class LoopbackCancellationFixture: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let finished = DispatchSemaphore(value: 0)
    private let streaming = TestSignal()

    init() throws {
        let listening = try makeLoopbackListener()
        listener = listening.descriptor
        port = listening.port
        start()
    }

    deinit {
        finished.signal()
        close(listener)
    }

    func finish() { finished.signal() }
    func waitUntilStreaming(seconds: Double) -> Bool { streaming.wait(seconds: seconds) }

    private func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            _ = receiveHTTPRequest(client)
            sendAll(client, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: ready\n\n")
            streaming.signal()
            _ = finished.wait(timeout: .now() + 5)
        }
    }
}

private final class LoopbackTruncatedSSEFixture: @unchecked Sendable {
    let port: Int
    private let listener: Int32

    init() throws {
        let listening = try makeLoopbackListener()
        listener = listening.descriptor
        port = listening.port
        start()
    }

    deinit { close(listener) }

    private func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            _ = receiveHTTPRequest(client)
            sendAll(
                client,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 1024\r\nConnection: close\r\n\r\ndata: partial\n\n"
            )
        }
    }
}

private final class LoopbackSSEFixture: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let secondEvent = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedRequest = ""
    private var sentSecond = false

    var requestText: String { lock.withLock { storedRequest } }
    var didSendSecondEvent: Bool { lock.withLock { sentSecond } }

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }) == 0 else {
            close(descriptor)
            throw POSIXError(.EIO)
        }
        listener = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
        start()
    }

    deinit {
        secondEvent.signal()
        close(listener)
    }

    func allowSecondEvent() { secondEvent.signal() }

    private func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            let request = receiveHTTPRequest(client)
            lock.withLock { storedRequest = request }
            sendAll(client, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: one\n\n")
            _ = secondEvent.wait(timeout: .now() + 5)
            lock.withLock { sentSecond = true }
            sendAll(client, "data: two\n\ndata: {\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":8,\"total_tokens\":20}}\n\n")
        }
    }
}

private func makeLoopbackListener() throws -> (descriptor: Int32, port: Int) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    var reuse: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
        close(descriptor)
        throw POSIXError(.EADDRINUSE)
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    guard withUnsafeMutablePointer(to: &address, { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }) == 0 else {
        close(descriptor)
        throw POSIXError(.EIO)
    }
    return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
}

private func sendGatewayRequestAndDisconnectAfterFirstEvent(port: Int) throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer {
        _ = shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
    let body = #"{"model":"public-model","stream":true,"messages":[]}"#
    sendAll(descriptor, "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer local-token\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while data.count < 128 * 1_024 {
        let count = recv(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { throw POSIXError(.ECONNRESET) }
        data.append(contentsOf: buffer.prefix(count))
        if String(decoding: data, as: UTF8.self).contains("data: ready\n\n") { return }
    }
    throw POSIXError(.EMSGSIZE)
}

private func gatewayURLRequest(port: Int) -> URLRequest {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
    request.httpMethod = "POST"
    request.httpBody = Data(#"{"model":"public-model","stream":true,"messages":[]}"#.utf8)
    request.setValue("Bearer local-token", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
}

private func sendRawStreamingGatewayRequest(port: Int) throws -> String {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
    let body = #"{"model":"public-model","stream":true,"messages":[]}"#
    sendAll(descriptor, "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer local-token\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while data.count < 128 * 1_024 {
        let count = recv(descriptor, &buffer, buffer.count, 0)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return String(decoding: data, as: UTF8.self)
}

private func sendStreamingGatewayRequest(port: Int, firstEventAtClient: TestSignal) throws -> String {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
    let body = #"{"model":"fast","stream":true,"messages":[]}"#
    sendAll(descriptor, "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer local-token\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    var signaled = false
    while true {
        let count = recv(descriptor, &buffer, buffer.count, 0)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
        if !signaled, String(decoding: data, as: UTF8.self).contains("data: one\n\n") {
            signaled = true
            firstEventAtClient.signal()
        }
    }
    return String(decoding: data, as: UTF8.self)
}

private func receiveHTTPRequest(_ descriptor: Int32) -> String {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while data.count < 128 * 1_024 {
        let count = recv(descriptor, &buffer, buffer.count, 0)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
        let text = String(decoding: data, as: UTF8.self)
        guard let headerRange = text.range(of: "\r\n\r\n") else { continue }
        let header = String(text[..<headerRange.lowerBound])
        if header.lowercased().contains("transfer-encoding: chunked") {
            if text.contains("upstream-fast") { break }
            continue
        }
        let contentLength = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
            let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("Content-Length") == .orderedSame else { return nil }
            return Int(fields[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }.first ?? 0
        let headerBytes = text[..<headerRange.upperBound].utf8.count
        if data.count >= headerBytes + contentLength { break }
    }
    return String(decoding: data, as: UTF8.self)
}

private func sendAll(_ descriptor: Int32, _ string: String) {
    let bytes = Array(string.utf8)
    var sent = 0
    while sent < bytes.count {
        let count = bytes.withUnsafeBytes { pointer in
            Darwin.send(descriptor, pointer.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
        }
        guard count > 0 else { return }
        sent += count
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
