import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import ModelMoorApplication
@testable import ModelMoorGateway
@testable import ModelMoorSystem
import ModelMoorCore

final class ModelMoorApplicationTests: XCTestCase {
    private func makeSession(
        _ name: String = UUID().uuidString,
        runtimeLockURL: URL? = nil,
        inspector: any APIInspecting = APIInspector(),
        sshConfigScanner: any SSHConfigScanning = SSHConfigScanner(),
        gatewayCoordinator: GatewayServiceCoordinator? = nil,
        cliProxyServiceFactory: @escaping CLIProxyServiceFactory = { dataDirectoryURL, handler in
            CLIProxyService(dataDirectoryURL: dataDirectoryURL, stateHandler: handler)
        },
        cliProxyManagementFactory: @escaping CLIProxyManagementFactory = { port, password in
            CLIProxyManagementClient(port: port, managementPassword: password)
        },
        subscriptionUsageProvider: (any SubscriptionUsageProviding)? = nil
    ) throws -> (ModelMoorSession, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorSessionTests-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = ModelMoorRuntimeProfile.make(
            .development,
            homeDirectory: directory,
            configurationHome: directory.appendingPathComponent("config", isDirectory: true)
        )
        let secretStore = HeadlessFileSecretStore(
            fileURL: directory.appendingPathComponent("secrets.json")
        )
        let session = try ModelMoorSession(
            profile: profile,
            secretStore: secretStore,
            usageStore: TokenUsageStore(
                fileURL: directory.appendingPathComponent("token-usage.jsonl")
            ),
            inspector: inspector,
            sshConfigScanner: sshConfigScanner,
            runtimeLockURL: runtimeLockURL ?? directory
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("runtime-owner.lock"),
            gatewayCoordinator: gatewayCoordinator,
            cliProxyServiceFactory: cliProxyServiceFactory,
            cliProxyManagementFactory: cliProxyManagementFactory,
            subscriptionUsageProvider: subscriptionUsageProvider
        )
        return (session, directory)
    }

    func testLoadEmitsSnapshotWithConnectOnLaunchTunnels() async throws {
        let (session, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }

        let box = SnapshotBox()
        let collector = Task {
            for await snapshot in session.snapshots() {
                box.append(snapshot)
                if snapshot.isLoaded { break }
            }
        }
        // Give the subscriber a chance to attach so it observes the pre-load
        // snapshot before load() mutates state.
        try await Task.sleep(for: .milliseconds(100))
        try await session.load()
        _ = await collector.value
        let updates = box.values

        XCTAssertEqual(updates.first?.isLoaded, false)
        XCTAssertEqual(updates.last?.isLoaded, true)
        XCTAssertEqual(updates.last?.runtimeState, .stopped)
        // The initial configuration prepares recommended cloud endpoints.
        XCTAssertFalse(updates.last?.configuration.endpoints.isEmpty ?? true)
    }

    func testStartRuntimeAcquiresOwnerAndRejectsSecondOwner() async throws {
        let (first, firstDirectory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: firstDirectory) }
        try await first.load()

        var configuration = await first.snapshot.configuration
        configuration.gateway = GatewayConfiguration(enabled: false)
        try await first.saveConfiguration(configuration)

        try await first.startRuntime(owner: "first")
        var snapshot = await first.snapshot
        XCTAssertEqual(snapshot.runtimeState, .running)
        XCTAssertEqual(first.recordedRuntimeOwner(), "pid=\(getpid()) owner=first")

        // A second session over the SAME lock file must not take over.
        let (second, secondDirectory) = try makeSession(
            runtimeLockURL: firstDirectory
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("runtime-owner.lock")
        )
        defer { try? FileManager.default.removeItem(at: secondDirectory) }
        try await second.load()
        do {
            try await second.startRuntime(owner: "second")
            XCTFail("Second runtime owner should be rejected")
        } catch let error as RuntimeOwnershipError {
            guard case .alreadyOwned = error else {
                return XCTFail("Expected alreadyOwned, got \(error)")
            }
        }
        await second.refreshRuntimeState()
        snapshot = await second.snapshot
        XCTAssertEqual(
            snapshot.runtimeState,
            .ownedExternally(owner: "pid=\(getpid()) owner=first")
        )

        await first.stopRuntime()
        snapshot = await first.snapshot
        XCTAssertEqual(snapshot.runtimeState, .stopped)

        // After a clean stop the second session may acquire the runtime.
        try await second.startRuntime(owner: "second")
        snapshot = await second.snapshot
        XCTAssertEqual(snapshot.runtimeState, .running)
        await second.stopRuntime()
    }

    func testRemoveEndpointCascadesThroughSession() async throws {
        let (session, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.load()

        let endpoint = APIEndpointConfiguration(
            name: "Cloud",
            source: .directHTTPS(originURL: URL(string: "https://api.example.com")!),
            authentication: .bearer
        )
        try await session.addEndpoint(endpoint, secret: "sk-test")
        var snapshot = await session.snapshot
        XCTAssertTrue(snapshot.configuration.endpoints.contains(where: { $0.id == endpoint.id }))

        let result = try await session.removeEndpoint(endpoint.id)
        XCTAssertEqual(result.removedEndpointIDs, [endpoint.id])
        snapshot = await session.snapshot
        XCTAssertFalse(snapshot.configuration.endpoints.contains(where: { $0.id == endpoint.id }))
    }

    func testGatewayStartsAndStopsWithRuntime() async throws {
        let coordinator = GatewayServiceCoordinator {
            GatewayService(upstreamCancellationObserver: nil, bindingPortOverride: 0)
        }
        let (session, directory) = try makeSession(gatewayCoordinator: coordinator)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.load()

        var configuration = await session.snapshot.configuration
        configuration.gateway = GatewayConfiguration(
            enabled: true,
            listenPort: 17_777,
            apiKeys: [GatewayAPIKeyConfiguration(name: "Test key")]
        )
        try await session.saveConfiguration(configuration)

        try await session.startRuntime(owner: "test")
        var snapshot = await session.snapshot
        guard case let .running(port) = snapshot.gatewayState else {
            return XCTFail("Expected the injected Gateway to bind an ephemeral loopback port")
        }
        XCTAssertGreaterThan(port, 0)

        await session.stopRuntime()
        snapshot = await session.snapshot
        XCTAssertEqual(snapshot.gatewayState, .stopped)
    }

    func testGatewayAndEndpointKeyCommandsRoundTrip() async throws {
        let (session, directory) = try makeSession(inspector: ImmediateInspector())
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.load()

        // Gateway key: create returns the secret once, persists config.
        let baselineKeyCount = await session.snapshot.configuration.gateway.apiKeys.count
        let secret = try await session.createGatewayAPIKey(name: "CI key")
        XCTAssertTrue(secret.hasPrefix("sk-"))
        var snapshot = await session.snapshot
        XCTAssertEqual(snapshot.configuration.gateway.apiKeys.count, baselineKeyCount + 1)
        let keyID = try XCTUnwrap(snapshot.configuration.gateway.apiKeys.first(where: { $0.name == "CI key" })?.id)

        // Rotate replaces the stored secret.
        let rotated = try await session.rotateGatewayAPIKey(keyID)
        XCTAssertTrue(rotated.hasPrefix("sk-"))
        XCTAssertNotEqual(rotated, secret)
        let revealed = try await session.revealGatewayAPIKey(keyID)
        XCTAssertEqual(revealed, rotated)

        // Disable + requiresAPIKey flag.
        try await session.setGatewayAPIKeyEnabled(keyID, enabled: false)
        try await session.setGatewayRequiresAPIKey(false)
        snapshot = await session.snapshot
        XCTAssertEqual(snapshot.configuration.gateway.apiKeys.first(where: { $0.id == keyID })?.enabled, false)
        XCTAssertFalse(snapshot.configuration.gateway.requiresAPIKey)

        // Remove deletes config and secret.
        try await session.removeGatewayAPIKey(keyID)
        snapshot = await session.snapshot
        XCTAssertFalse(snapshot.configuration.gateway.apiKeys.contains(where: { $0.id == keyID }))
        let gatewayKeyStillThere = await session.hasToken(forAPIKey: keyID)
        XCTAssertFalse(gatewayKeyStillThere)

        // Endpoint key lifecycle.
        let endpoint = APIEndpointConfiguration(
            name: "Cloud",
            source: .directHTTPS(originURL: URL(string: "https://api.example.com")!),
            authentication: .bearer
        )
        try await session.addEndpoint(endpoint, secret: nil)
        let endpointKeyID = try await session.createEndpointAPIKey(
            endpointID: endpoint.id,
            name: "Personal",
            secret: "sk-endpoint-1"
        )
        let endpointKeyPresent = await session.hasToken(forAPIKey: endpointKeyID)
        XCTAssertTrue(endpointKeyPresent)
        snapshot = await session.snapshot
        XCTAssertTrue(snapshot.availableEndpointAPIKeyIDs.contains(endpointKeyID))
        try await session.replaceEndpointAPIKey(endpointKeyID, endpointID: endpoint.id, secret: "sk-endpoint-2")

        let duplicateID = try await session.duplicateEndpoint(endpoint.id)
        snapshot = await session.snapshot
        let duplicate = try XCTUnwrap(snapshot.configuration.endpoints.first(where: { $0.id == duplicateID }))
        let duplicateActiveKeyID = try XCTUnwrap(duplicate.activeAPIKeyID)
        XCTAssertEqual(duplicate.name, "Cloud copy")
        XCTAssertTrue(snapshot.availableEndpointAPIKeyIDs.contains(duplicateActiveKeyID))

        try await session.removeEndpointAPIKey(endpointKeyID, endpointID: endpoint.id)
        let endpointKeyStillThere = await session.hasToken(forAPIKey: endpointKeyID)
        XCTAssertFalse(endpointKeyStillThere)
        snapshot = await session.snapshot
        // validated() auto-provisions a "Default key" for bearer endpoints;
        // the created key must be gone while defaults may remain.
        let keys = snapshot.configuration.endpoints.first(where: { $0.id == endpoint.id })?.apiKeys ?? []
        XCTAssertFalse(keys.contains(where: { $0.id == endpointKeyID }))

        let mapping = PortMappingConfiguration(name: "API", listenPort: 18_889, destinationPort: 8_000)
        let tunnel = TunnelConfiguration(name: "GPU", sshHost: "gpu", mappings: [mapping])
        let sshEndpoint = APIEndpointConfiguration(
            name: "GPU API",
            source: .sshMapping(mappingID: mapping.id, originScheme: .http),
            authentication: .bearer
        )
        try await session.addSSHEndpoint(sshEndpoint, tunnel: tunnel, secret: "sk-ssh")
        snapshot = await session.snapshot
        XCTAssertTrue(snapshot.configuration.tunnels.contains(where: { $0.id == tunnel.id }))
        XCTAssertTrue(snapshot.configuration.endpoints.contains(where: { $0.id == sshEndpoint.id }))
        XCTAssertTrue(snapshot.availableEndpointAPIKeyIDs.contains(sshEndpoint.activeAPIKeyID!))
    }

    func testTemporaryInspectionAndSSHDiscoveryAreSessionOwnedAndCoalesced() async throws {
        let inspector = CapturingInspector()
        let scanner = DelayedSSHConfigScanner(
            targets: [SSHHostTarget(alias: "gpu", sourcePath: "/tmp/ssh/config")]
        )
        let (session, directory) = try makeSession(
            inspector: inspector,
            sshConfigScanner: scanner
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.load()

        let draft = APIEndpointConfiguration(
            name: "Draft",
            source: .directHTTPS(originURL: URL(string: "https://draft.example.com")!),
            authentication: .bearer
        )
        let inspection = await session.inspectTemporaryEndpoint(draft, secret: "  sk-draft  ")
        XCTAssertEqual(inspection.endpointID, draft.id)
        let capturedSecret = await inspector.lastSecret
        XCTAssertEqual(capturedSecret, "sk-draft")
        let snapshotAfterDraft = await session.snapshot
        XCTAssertNil(snapshotAfterDraft.inspections[draft.id])

        async let first = session.refreshSSHTargets()
        async let second = session.refreshSSHTargets()
        let (firstTargets, secondTargets) = try await (first, second)
        XCTAssertEqual(firstTargets, secondTargets)
        XCTAssertEqual(scanner.callCount, 1)
        let snapshot = await session.snapshot
        XCTAssertEqual(snapshot.sshTargets, firstTargets)
        XCTAssertFalse(snapshot.isRefreshingSSHTargets)
    }

    func testSuspendAndResumeRuntimePausesTunnels() async throws {
        let (session, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.load()
        var configuration = await session.snapshot.configuration
        configuration.gateway = GatewayConfiguration(enabled: false)
        try await session.saveConfiguration(configuration)
        try await session.startRuntime(owner: "test")

        await session.suspendRuntime(reason: "Waiting for machine to wake")
        await session.resumeRuntime()
        await session.stopRuntime()
        // Smoke-level: suspend/resume must not throw, deadlock or lose ownership.
        let finalState = await session.snapshot.runtimeState
        XCTAssertEqual(finalState, .stopped)
    }

    func testEndpointRefreshUsesBoundedParallelismAndCoalescesCallers() async throws {
        let probe = InspectionConcurrencyProbe()
        let inspector = DelayedInspector(probe: probe)
        let (session, directory) = try makeSession(inspector: inspector)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.load()

        let endpoints = (0..<10).map { index in
            APIEndpointConfiguration(
                name: "Endpoint \(index)",
                source: .directHTTPS(originURL: URL(string: "https://api\(index).example.com")!),
                authentication: .none
            )
        }
        var configuration = await session.snapshot.configuration
        configuration.tunnels = []
        configuration.endpoints = endpoints
        configuration.routes = []
        configuration.gateway.enabled = false
        try await session.saveConfiguration(configuration)

        async let first: Void = session.inspectAllEndpoints()
        async let second: Void = session.inspectAllEndpoints()
        _ = await (first, second)

        let measurements = await probe.measurements
        XCTAssertEqual(measurements.callCount, endpoints.count)
        XCTAssertGreaterThan(measurements.maximumConcurrent, 1)
        XCTAssertLessThanOrEqual(measurements.maximumConcurrent, 4)
        let snapshot = await session.snapshot
        XCTAssertEqual(snapshot.inspections.count, endpoints.count)
    }

    func testSnapshotStreamCoalescesBacklogToLatestState() async throws {
        let (session, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.load()

        var iterator = session.snapshots().makeAsyncIterator()
        _ = await iterator.next()

        for index in 1...3 {
            var configuration = await session.snapshot.configuration
            configuration.endpoints[0].name = "Update \(index)"
            try await session.saveConfiguration(configuration)
        }

        let latest = await iterator.next()
        XCTAssertEqual(latest?.configuration.endpoints[0].name, "Update 3")
    }

    func testManagedSubscriptionLifecycleAndCommandsAreSessionOwned() async throws {
        let runtimeProbe = FakeCLIProxyRuntimeProbe()
        let managementState = FakeCLIProxyManagementState()
        let account = CLIProxyAccount(
            id: "account-1",
            name: "codex-account.json",
            provider: "codex",
            email: "person@example.com"
        )
        await managementState.setAccounts([account])
        let usageProvider = FakeSubscriptionUsageProvider()
        let (session, directory) = try makeSession(
            inspector: ImmediateInspector(),
            cliProxyServiceFactory: { _, handler in
                FakeCLIProxyService(probe: runtimeProbe, stateHandler: handler)
            },
            cliProxyManagementFactory: { _, _ in
                FakeCLIProxyManagementClient(state: managementState)
            },
            subscriptionUsageProvider: usageProvider
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try await session.load()
        var configuration = await session.snapshot.configuration
        configuration.gateway.enabled = false
        configuration.cliProxy.enabled = true
        configuration.reconcileManagedCLIProxyEndpoint()
        try await session.saveConfiguration(configuration)

        // Configuration edits alone must not launch a duplicate helper from a
        // read-only Session. Runtime ownership is the lifecycle boundary.
        var runtimeMeasurements = await runtimeProbe.measurements
        XCTAssertEqual(runtimeMeasurements.startCount, 0)
        try await session.startRuntime(owner: "subscription-test")

        var snapshot = await session.snapshot
        XCTAssertEqual(snapshot.subscriptions.runtimeState, .running(port: configuration.cliProxy.listenPort))
        XCTAssertEqual(snapshot.subscriptions.accounts, [account])
        XCTAssertTrue(snapshot.subscriptions.isUsageProviderAvailable)
        runtimeMeasurements = await runtimeProbe.measurements
        XCTAssertEqual(runtimeMeasurements.startCount, 1)

        let login = try await session.startSubscriptionLogin(.codex)
        XCTAssertEqual(login.url.absoluteString, "https://example.com/device")
        snapshot = await session.snapshot
        XCTAssertEqual(snapshot.subscriptions.activeProvider, .codex)
        XCTAssertEqual(snapshot.subscriptions.activeLogin?.userCode, "ABCD-EFGH")

        await session.cancelSubscriptionLogin()
        snapshot = await session.snapshot
        XCTAssertNil(snapshot.subscriptions.activeProvider)
        XCTAssertNil(snapshot.subscriptions.activeLogin)
        let cancelledStates = await managementState.cancelledStates
        XCTAssertEqual(cancelledStates, ["login-state"])

        try await session.setSubscriptionAccountEnabled(account, enabled: false)
        snapshot = await session.snapshot
        XCTAssertEqual(snapshot.subscriptions.accounts.first?.disabled, true)
        XCTAssertTrue(snapshot.subscriptions.updatingAccountIDs.isEmpty)

        await session.refreshSubscriptionUsage()
        snapshot = await session.snapshot
        XCTAssertEqual(snapshot.subscriptions.usage[account.id]?.source, "test")
        XCTAssertFalse(snapshot.subscriptions.isRefreshingUsage)

        await session.suspendRuntime(reason: "test sleep")
        snapshot = await session.snapshot
        XCTAssertEqual(snapshot.subscriptions.runtimeState, .stopped)
        runtimeMeasurements = await runtimeProbe.measurements
        XCTAssertEqual(runtimeMeasurements.stopCount, 1)

        await session.resumeRuntime()
        snapshot = await session.snapshot
        XCTAssertEqual(snapshot.subscriptions.runtimeState, .running(port: configuration.cliProxy.listenPort))
        runtimeMeasurements = await runtimeProbe.measurements
        XCTAssertEqual(runtimeMeasurements.startCount, 2)

        await session.stopRuntime()
        snapshot = await session.snapshot
        XCTAssertEqual(snapshot.subscriptions.runtimeState, .stopped)
        XCTAssertTrue(snapshot.subscriptions.accounts.isEmpty)
        runtimeMeasurements = await runtimeProbe.measurements
        XCTAssertGreaterThanOrEqual(runtimeMeasurements.stopCount, 2)
    }

    func testManagedSubscriptionCommandsFollowRuntimeAndHelperOwnership() {
        var availability = ManagedSubscriptionInteractionPolicy.availability(
            runtimeState: .ownedExternally(owner: "modelmoor-tui"),
            cliProxyState: .running(port: 18_317),
            hasActiveLogin: false
        )
        XCTAssertEqual(
            availability,
            ManagedSubscriptionActionAvailability(
                canStartLogin: false,
                canRefreshAccounts: false,
                canMutateAccounts: false
            )
        )

        availability = ManagedSubscriptionInteractionPolicy.availability(
            runtimeState: .running,
            cliProxyState: .stopped,
            hasActiveLogin: false
        )
        XCTAssertTrue(availability.canStartLogin)
        XCTAssertFalse(availability.canRefreshAccounts)
        XCTAssertFalse(availability.canMutateAccounts)

        availability = ManagedSubscriptionInteractionPolicy.availability(
            runtimeState: .running,
            cliProxyState: .running(port: 18_317),
            hasActiveLogin: true
        )
        XCTAssertFalse(availability.canStartLogin)
        XCTAssertTrue(availability.canRefreshAccounts)
        XCTAssertTrue(availability.canMutateAccounts)
    }

    func testManagedSubscriptionRetryIsCancelledWhileRuntimeIsSuspended() async throws {
        let runtimeProbe = FakeCLIProxyRuntimeProbe()
        let (session, directory) = try makeSession(
            inspector: ImmediateInspector(),
            cliProxyServiceFactory: { _, handler in
                FailingCLIProxyService(probe: runtimeProbe, stateHandler: handler)
            }
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try await session.load()
        var configuration = await session.snapshot.configuration
        configuration.gateway.enabled = false
        configuration.cliProxy.enabled = true
        configuration.reconcileManagedCLIProxyEndpoint()
        try await session.saveConfiguration(configuration)
        try await session.startRuntime(owner: "subscription-retry-test")

        var measurements = await runtimeProbe.measurements
        XCTAssertEqual(measurements.startCount, 1)
        try await Task.sleep(for: .milliseconds(50))
        await session.suspendRuntime(reason: "test sleep")
        try await Task.sleep(for: .milliseconds(1_200))
        measurements = await runtimeProbe.measurements
        XCTAssertEqual(
            measurements.startCount,
            1,
            "A cancelled one-second retry must not restart the helper during sleep"
        )
        let suspendedSnapshot = await session.snapshot
        XCTAssertEqual(suspendedSnapshot.subscriptions.runtimeState, .stopped)
        await session.stopRuntime()
    }

    func testSubscriptionLoginPreservesHelperStartupFailure() async throws {
        let runtimeProbe = FakeCLIProxyRuntimeProbe()
        let (session, directory) = try makeSession(
            inspector: ImmediateInspector(),
            cliProxyServiceFactory: { _, handler in
                FailingCLIProxyService(probe: runtimeProbe, stateHandler: handler)
            }
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try await session.load()
        var configuration = await session.snapshot.configuration
        configuration.gateway.enabled = false
        configuration.cliProxy.enabled = true
        configuration.reconcileManagedCLIProxyEndpoint()
        try await session.saveConfiguration(configuration)
        try await session.startRuntime(owner: "subscription-login-failure-test")

        do {
            _ = try await session.startSubscriptionLogin(.codex)
            XCTFail("Expected the injected CLIProxyAPI start failure")
        } catch {
            XCTAssertEqual(
                error as? ManagedSubscriptionError,
                .loginFailed("Could not launch CLIProxyAPI: injected failure")
            )
        }
        await session.stopRuntime()
    }
}

private actor InspectionConcurrencyProbe {
    private var active = 0
    private var maximum = 0
    private var calls = 0

    func begin() {
        active += 1
        calls += 1
        maximum = max(maximum, active)
    }

    func end() {
        active -= 1
    }

    var measurements: (callCount: Int, maximumConcurrent: Int) {
        (calls, maximum)
    }
}

private struct DelayedInspector: APIInspecting {
    let probe: InspectionConcurrencyProbe

    func inspect(
        _ endpoint: APIEndpointConfiguration,
        mappings: [UUID: PortMappingConfiguration],
        secret: String?
    ) async -> EndpointInspection {
        await probe.begin()
        try? await Task.sleep(for: .milliseconds(40))
        await probe.end()
        return EndpointInspection(
            endpointID: endpoint.id,
            url: try? EndpointURLResolver.resolve(endpoint, mappings: mappings),
            statusCode: 200,
            models: [RemoteModelMetadata(id: "test-model")],
            classification: .llmAPI
        )
    }
}

private struct ImmediateInspector: APIInspecting {
    func inspect(
        _ endpoint: APIEndpointConfiguration,
        mappings: [UUID: PortMappingConfiguration],
        secret: String?
    ) async -> EndpointInspection {
        EndpointInspection(
            endpointID: endpoint.id,
            url: try? EndpointURLResolver.resolve(endpoint, mappings: mappings),
            statusCode: 200,
            models: [RemoteModelMetadata(id: "managed-model")],
            classification: .llmAPI
        )
    }
}

private actor CapturingInspector: APIInspecting {
    private(set) var lastSecret: String?

    func inspect(
        _ endpoint: APIEndpointConfiguration,
        mappings: [UUID: PortMappingConfiguration],
        secret: String?
    ) async -> EndpointInspection {
        lastSecret = secret
        return EndpointInspection(
            endpointID: endpoint.id,
            url: try? EndpointURLResolver.resolve(endpoint, mappings: mappings),
            statusCode: 200,
            models: [RemoteModelMetadata(id: "draft-model")],
            classification: .llmAPI
        )
    }
}

private final class DelayedSSHConfigScanner: SSHConfigScanning, @unchecked Sendable {
    private let lock = NSLock()
    private let targets: [SSHHostTarget]
    private var storedCallCount = 0

    init(targets: [SSHHostTarget]) {
        self.targets = targets
    }

    func discoverTargets() throws -> [SSHHostTarget] {
        lock.lock()
        storedCallCount += 1
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.05)
        return targets
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }
}

private actor FakeCLIProxyRuntimeProbe {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func recordStart() { startCount += 1 }
    func recordStop() { stopCount += 1 }

    var measurements: (startCount: Int, stopCount: Int) {
        (startCount, stopCount)
    }
}

private actor FakeCLIProxyService: CLIProxyServicing {
    private(set) var state: CLIProxyRuntimeState = .stopped
    private let probe: FakeCLIProxyRuntimeProbe
    private let stateHandler: @Sendable (CLIProxyRuntimeState) -> Void

    init(
        probe: FakeCLIProxyRuntimeProbe,
        stateHandler: @escaping @Sendable (CLIProxyRuntimeState) -> Void
    ) {
        self.probe = probe
        self.stateHandler = stateHandler
    }

    func start(
        configuration: CLIProxyConfiguration,
        apiKey: String,
        managementPassword: String
    ) async throws {
        if case .running(port: configuration.listenPort) = state { return }
        await probe.recordStart()
        state = .starting
        stateHandler(state)
        state = .running(port: configuration.listenPort)
        stateHandler(state)
    }

    func stop() async {
        await probe.recordStop()
        state = .stopped
        stateHandler(state)
    }
}

private actor FailingCLIProxyService: CLIProxyServicing {
    private(set) var state: CLIProxyRuntimeState = .stopped
    private let probe: FakeCLIProxyRuntimeProbe
    private let stateHandler: @Sendable (CLIProxyRuntimeState) -> Void

    init(
        probe: FakeCLIProxyRuntimeProbe,
        stateHandler: @escaping @Sendable (CLIProxyRuntimeState) -> Void
    ) {
        self.probe = probe
        self.stateHandler = stateHandler
    }

    func start(
        configuration: CLIProxyConfiguration,
        apiKey: String,
        managementPassword: String
    ) async throws {
        await probe.recordStart()
        state = .failed("injected failure")
        stateHandler(state)
        throw CLIProxyServiceError.launch("injected failure")
    }

    func stop() async {
        await probe.recordStop()
        state = .stopped
        stateHandler(state)
    }
}

private actor FakeCLIProxyManagementState {
    private var storedAccounts: [CLIProxyAccount] = []
    private(set) var cancelledStates: [String] = []

    func setAccounts(_ accounts: [CLIProxyAccount]) {
        storedAccounts = accounts
    }

    var accounts: [CLIProxyAccount] { storedAccounts }

    func cancel(state: String) {
        cancelledStates.append(state)
    }

    func delete(name: String) {
        storedAccounts.removeAll { $0.name == name }
    }

    func setDisabled(id: String, disabled: Bool) {
        guard let index = storedAccounts.firstIndex(where: { $0.id == id }) else { return }
        storedAccounts[index].disabled = disabled
    }
}

private struct FakeCLIProxyManagementClient: CLIProxyManaging {
    let state: FakeCLIProxyManagementState

    func startLogin(_ provider: CLIProxyLoginProvider) async throws -> CLIProxyLoginSession {
        CLIProxyLoginSession(
            status: "ok",
            url: URL(string: "https://example.com/device")!,
            state: "login-state",
            flow: "device",
            userCode: "ABCD-EFGH"
        )
    }

    func loginStatus(state: String) async throws -> CLIProxyAuthStatus {
        CLIProxyAuthStatus(status: "pending")
    }

    func cancelLogin(state: String) async throws {
        await self.state.cancel(state: state)
    }

    func accounts() async throws -> [CLIProxyAccount] {
        await state.accounts
    }

    func deleteAccount(named name: String) async throws {
        await state.delete(name: name)
    }

    func setAccountDisabled(_ account: CLIProxyAccount, disabled: Bool) async throws {
        await state.setDisabled(id: account.id, disabled: disabled)
    }
}

private struct FakeSubscriptionUsageProvider: SubscriptionUsageProviding {
    let isAvailable = true

    func usage(for accounts: [CLIProxyAccount]) async -> [SubscriptionUsageSnapshot] {
        accounts.map {
            SubscriptionUsageSnapshot(id: $0.id, accountEmail: $0.email, source: "test")
        }
    }
}

private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AppSnapshot] = []
    var values: [AppSnapshot] { lock.withLock { stored } }
    func append(_ snapshot: AppSnapshot) { lock.withLock { stored.append(snapshot) } }
}
