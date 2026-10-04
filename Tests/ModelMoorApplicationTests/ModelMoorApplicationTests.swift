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
    func testReloadConfigurationImportsAliasWithoutRewritingDiskAndRejectsInvalidData() async throws {
        let (session, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.load()
        var configuration = await session.snapshot.configuration
        let endpoint = APIEndpointConfiguration(
            name: "Local", source: .directHTTPS(originURL: URL(string: "http://localhost:8080")!)
        )
        let route = ModelRouteConfiguration(publicModel: "old-alias", endpointID: endpoint.id, upstreamModel: "vendor-model")
        configuration.endpoints.append(endpoint)
        configuration.routes = [route]
        configuration.gateway.enabled = false
        try await session.saveConfiguration(configuration)
        let profile = ModelMoorRuntimeProfile.make(
            .development, homeDirectory: directory,
            configurationHome: directory.appendingPathComponent("config", isDirectory: true)
        )
        configuration.routes[0].publicModel = "new-alias"
        let editedData = try JSONEncoder().encode(configuration)
        try editedData.write(to: profile.configurationURL)
        try await session.reloadConfiguration()
        let reloaded = await session.snapshot.configuration
        XCTAssertEqual(reloaded.routes[0].publicModel, "new-alias")
        XCTAssertEqual(reloaded.routes[0].upstreamModel, "vendor-model")
        XCTAssertEqual(reloaded.routes[0].id, route.id)
        XCTAssertEqual(try Data(contentsOf: profile.configurationURL), editedData)
        try Data("invalid JSON".utf8).write(to: profile.configurationURL)
        do {
            try await session.reloadConfiguration()
            XCTFail("Invalid configuration must not replace active state")
        } catch {}
        let unchanged = await session.snapshot.configuration
        XCTAssertEqual(unchanged, reloaded)
    }

    func testModelBudgetUsageReadsPersistedCalendarTotals() async throws {
        let (session, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = ModelMoorRuntimeProfile.make(
            .development, homeDirectory: directory,
            configurationHome: directory.appendingPathComponent("config", isDirectory: true)
        )
        let route = ModelRouteConfiguration(publicModel: "test", endpointID: UUID(), upstreamModel: "test")
        let ledger = GatewayBudgetLedger(fileURL: profile.tokenUsageURL.deletingLastPathComponent().appendingPathComponent("model-budgets.json"))
        ledger.record(route: route, tokens: 50, inputTokens: 30, outputTokens: 20)
        let report = await session.modelBudgetUsage(for: [route])
        XCTAssertEqual(report[route.id]?.count, 3)
        XCTAssertEqual(report[route.id]?.first?.tokens, 50)
        XCTAssertFalse(try XCTUnwrap(report[route.id]?.first).isBlocked)
    }

    private func makeSession(
        _ name: String = UUID().uuidString,
        runtimeLockURL: URL? = nil,
        inspector: any APIInspecting = APIInspector(),
        sshConfigScanner: any SSHConfigScanning = SSHConfigScanner(),
        gatewayCoordinator: GatewayServiceCoordinator? = nil,
        grokExecutableURL: URL? = GrokBuildSubscriptionAPIAdapter.findExecutable(),
        kimiExecutableURL: URL? = KimiCodeSubscriptionAPIAdapter.findExecutable()
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
            grokExecutableURL: grokExecutableURL,
            kimiExecutableURL: kimiExecutableURL
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

    func testAddingEndpointWithSecretMarksDefaultAPIKeyAvailable() async throws {
        let (session, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.load()

        let endpoint = APIEndpointConfiguration(
            name: "Cloud",
            source: .directHTTPS(originURL: URL(string: "https://api.example.com")!),
            authentication: .bearer
        )
        try await session.addEndpoint(endpoint, secret: "sk-test")

        let keyID = try XCTUnwrap(endpoint.activeAPIKeyID)
        let secretStore = HeadlessFileSecretStore(
            fileURL: directory.appendingPathComponent("secrets.json")
        )
        XCTAssertEqual(try secretStore.token(for: keyID), "sk-test")
        let snapshot = await session.snapshot
        XCTAssertTrue(snapshot.availableEndpointAPIKeyIDs.contains(keyID))
        let keyIsAvailable = await session.hasToken(forAPIKey: keyID)
        XCTAssertTrue(keyIsAvailable)
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
        let missingKeyID = try XCTUnwrap(endpoint.activeAPIKeyID)
        do {
            _ = try await session.revealEndpointAPIKey(missingKeyID, endpointID: endpoint.id)
            XCTFail("Missing secrets must not be generated by reveal")
        } catch is ConfigurationError {}
        let endpointKeyID = try await session.createEndpointAPIKey(
            endpointID: endpoint.id,
            name: "Personal",
            secret: "sk-endpoint-1"
        )
        let endpointKeyPresent = await session.hasToken(forAPIKey: endpointKeyID)
        XCTAssertTrue(endpointKeyPresent)
        let endpointSecret = try await session.revealEndpointAPIKey(endpointKeyID, endpointID: endpoint.id)
        XCTAssertEqual(endpointSecret, "sk-endpoint-1")
        try await session.renameEndpointAPIKey(endpointKeyID, endpointID: endpoint.id, name: "  Work  ")
        let renamedSnapshot = await session.snapshot
        XCTAssertEqual(renamedSnapshot.configuration.endpoints.first(where: { $0.id == endpoint.id })?.apiKeys.first(where: { $0.id == endpointKeyID })?.name, "Work")
        let renamedSecret = try await session.revealEndpointAPIKey(endpointKeyID, endpointID: endpoint.id)
        XCTAssertEqual(renamedSecret, endpointSecret)
        let alternateKeyID = try await session.createEndpointAPIKey(endpointID: endpoint.id, name: "Alternate", secret: "sk-alternate")
        try await session.selectEndpointAPIKey(endpointKeyID, endpointID: endpoint.id)
        let selectedSnapshot = await session.snapshot
        XCTAssertEqual(selectedSnapshot.configuration.endpoints.first(where: { $0.id == endpoint.id })?.activeAPIKeyID, endpointKeyID)
        try await session.removeEndpointAPIKey(alternateKeyID, endpointID: endpoint.id)
        snapshot = await session.snapshot
        XCTAssertTrue(snapshot.availableEndpointAPIKeyIDs.contains(endpointKeyID))
        try await session.replaceEndpointAPIKey(endpointKeyID, endpointID: endpoint.id, secret: "sk-endpoint-2")
        let replacedSecret = try await session.revealEndpointAPIKey(endpointKeyID, endpointID: endpoint.id)
        XCTAssertEqual(replacedSecret, "sk-endpoint-2")

        let duplicateID = try await session.duplicateEndpoint(endpoint.id)
        do {
            _ = try await session.revealEndpointAPIKey(endpointKeyID, endpointID: duplicateID)
            XCTFail("A key from another endpoint must not be revealed")
        } catch is ConfigurationError {}
        snapshot = await session.snapshot
        let duplicate = try XCTUnwrap(snapshot.configuration.endpoints.first(where: { $0.id == duplicateID }))
        let duplicateActiveKeyID = try XCTUnwrap(duplicate.activeAPIKeyID)
        XCTAssertEqual(duplicate.name, "Cloud copy")
        XCTAssertTrue(snapshot.availableEndpointAPIKeyIDs.contains(duplicateActiveKeyID))

        try await session.removeEndpointAPIKey(endpointKeyID, endpointID: endpoint.id)
        do {
            _ = try await session.revealEndpointAPIKey(endpointKeyID, endpointID: endpoint.id)
            XCTFail("Removed keys must not be revealed")
        } catch is ConfigurationError {}
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

    func testNativeSubscriptionCommandsFollowRuntimeOwnership() {
        var availability = ManagedSubscriptionInteractionPolicy.availability(
            runtimeState: .ownedExternally(owner: "modelmoor-tui"),
            hasActiveLogin: false,
            hasAccounts: true
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
            hasActiveLogin: false,
            hasAccounts: false
        )
        XCTAssertTrue(availability.canStartLogin)
        XCTAssertTrue(availability.canRefreshAccounts)
        XCTAssertFalse(availability.canMutateAccounts)

        availability = ManagedSubscriptionInteractionPolicy.availability(
            runtimeState: .running,
            hasActiveLogin: true,
            hasAccounts: true
        )
        XCTAssertFalse(availability.canStartLogin)
        XCTAssertTrue(availability.canRefreshAccounts)
        XCTAssertTrue(availability.canMutateAccounts)
    }

    func testNativeSubscriptionAccountsLoadFromModelMoorSecretStore() async throws {
        let (session, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credential = SubscriptionOAuthCredential(accessToken: "access", refreshToken: "refresh")
        let account = try await session.subscriptionCredentialVault.save(
            provider: .codex,
            user: "codex@example.test",
            plan: "plus",
            credential: credential
        )

        try await session.startRuntime(owner: "native-subscription-test")
        defer { Task { await session.stopRuntime() } }
        try await session.refreshSubscriptionAccounts()
        let snapshot = await session.snapshot
        XCTAssertEqual(snapshot.subscriptions.accounts.map(\.id), [account.id.uuidString])
        XCTAssertEqual(snapshot.subscriptions.accounts.first?.provider, "codex")
        XCTAssertEqual(
            snapshot.configuration.endpoints.first?.source,
            .modelMoorSubscription
        )
        await session.stopRuntime()
    }

    func testGrokDeviceLoginFlowsThroughTheNativeSessionWithoutCLIProxyAPI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("grok")
        let script = """
        #!/bin/sh
        [ "$1" = "login" ] && [ "$2" = "--device-auth" ] || exit 9
        [ "$HOME/.grok" = "$GROK_HOME" ] || exit 8
        printf 'Open this URL: https://x.ai/device?user_code=MM-456\\n'
        sleep 1
        printf '%s' '{"https://auth.x.ai::test":{"key":"grok-session-token","email":"native-grok@example.test"}}' > "$GROK_HOME/auth.json"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let (session, sessionDirectory) = try makeSession(grokExecutableURL: executable)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        try await session.startRuntime(owner: "native-grok-login-test")
        let login = try await session.startSubscriptionLogin(.xai)
        XCTAssertEqual(login.url.host, "x.ai")
        var connected = false
        for _ in 0..<80 {
            let snapshot = await session.snapshot
            if snapshot.subscriptions.accounts.contains(where: { $0.provider == "xai" }) {
                connected = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(connected, "Grok login should be imported into ModelMoor's account pool")
        await session.stopRuntime()
    }

    func testKimiDeviceLoginFlowsThroughNativeSessionWithoutCLIProxyAPI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("kimi")
        let script = """
        #!/bin/sh
        [ "$1" = "login" ] && [ "$2" = "--region" ] && [ "$3" = "global" ] || exit 9
        mkdir -p "$KIMI_CODE_HOME/credentials"
        printf 'Open this URL: https://www.kimi.com/code/login?user_code=MM-789\\n'
        sleep 1
        printf '%s' '{"email":"native-kimi@example.test","access_token":"kimi-session-token"}' > "$KIMI_CODE_HOME/credentials/kimi-code.json"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let (session, sessionDirectory) = try makeSession(kimiExecutableURL: executable)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        try await session.startRuntime(owner: "native-kimi-login-test")
        let login = try await session.startSubscriptionLogin(.kimi)
        XCTAssertEqual(login.url.host, "www.kimi.com")
        var connected = false
        for _ in 0..<80 {
            if (await session.snapshot).subscriptions.accounts.contains(where: { $0.provider == "kimi" }) {
                connected = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(connected, "Kimi login should be imported into ModelMoor's account pool")
        await session.stopRuntime()
    }

    func testNativeClaudeModelsAreDiscoveredWithoutStartingCLIProxyAPI() async throws {
        let (session, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await session.subscriptionCredentialVault.save(
            provider: .claude,
            user: "claude@example.test",
            plan: "pro",
            credential: SubscriptionOAuthCredential(accessToken: "access", refreshToken: "refresh")
        )

        try await session.startRuntime(owner: "native-claude-subscription-test")
        try await session.refreshSubscriptionState()
        let snapshot = await session.snapshot
        let models = snapshot.inspections[APIEndpointConfiguration.nativeSubscriptionEndpointID]?.models ?? []
        XCTAssertEqual(Set(models.map(\.id)), Set(["claude/sonnet", "claude/opus", "claude/haiku"]))
        await session.stopRuntime()
    }

    func testNativeGrokModelsAreDiscoveredWithoutStartingCLIProxyAPI() async throws {
        let (session, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credential = GrokBuildSubscriptionCredential(
            email: "grok@example.test",
            authFile: Data(#"{"https://auth.x.ai::test":{"key":"token","email":"grok@example.test"}}"#.utf8)
        )
        _ = try await session.subscriptionCredentialVault.save(
            provider: .xai,
            user: credential.email,
            credential: credential.storedOAuthCredential
        )

        try await session.startRuntime(owner: "native-grok-subscription-test")
        try await session.refreshSubscriptionState()
        let snapshot = await session.snapshot
        let models = snapshot.inspections[APIEndpointConfiguration.nativeSubscriptionEndpointID]?.models ?? []
        XCTAssertEqual(Set(models.map(\.id)), Set(["grok/grok-4.7"]))
        XCTAssertEqual(snapshot.subscriptions.accounts.first?.provider, "xai")
        await session.stopRuntime()
    }

    func testNativeKimiModelsAreDiscoveredWithoutStartingCLIProxyAPI() async throws {
        let (session, directory) = try makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = KimiCodeSubscriptionProfile(credentialFiles: [
            "kimi-code.json": Data(#"{"access_token":"test-token"}"#.utf8)
        ])
        _ = try await session.subscriptionCredentialVault.save(
            provider: .kimi,
            user: "Kimi Code account",
            credential: profile.storedOAuthCredential
        )

        try await session.startRuntime(owner: "native-kimi-subscription-test")
        try await session.refreshSubscriptionState()
        let snapshot = await session.snapshot
        let models = snapshot.inspections[APIEndpointConfiguration.nativeSubscriptionEndpointID]?.models ?? []
        XCTAssertEqual(Set(models.map(\.id)), Set(["kimi/k3"]))
        XCTAssertEqual(snapshot.subscriptions.accounts.first?.provider, "kimi")
        await session.stopRuntime()
    }

    func testLegacySubscriptionProxyCannotBeReenabledOrStarted() async throws {
        let (session, directory) = try makeSession(inspector: ImmediateInspector())
        defer { try? FileManager.default.removeItem(at: directory) }

        try await session.load()
        var configuration = await session.snapshot.configuration
        configuration.endpoints.append(.managedCLIProxy(
            id: APIEndpointConfiguration.nativeSubscriptionEndpointID,
            port: 18_317
        ))
        XCTAssertThrowsError(try configuration.validated())
    }

    func testLegacySubscriptionProxyConfigurationFailsBeforeLogin() async throws {
        let (session, directory) = try makeSession(inspector: ImmediateInspector())
        defer { try? FileManager.default.removeItem(at: directory) }

        try await session.load()
        var configuration = await session.snapshot.configuration
        configuration.endpoints.append(.managedCLIProxy(
            id: APIEndpointConfiguration.nativeSubscriptionEndpointID,
            port: 18_317
        ))
        XCTAssertThrowsError(try configuration.validated())
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

private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AppSnapshot] = []
    var values: [AppSnapshot] { lock.withLock { stored } }
    func append(_ snapshot: AppSnapshot) { lock.withLock { stored.append(snapshot) } }
}
