import Foundation
import Darwin
import XCTest
@testable import ModelMoorCore

final class ModelMoorCoreTests: XCTestCase {
    func testUnifiedAPIKeyFormattingUsesSKPrefixAndURLSafePayload() {
        let key = KeychainTokenStore.formatGatewayAPIKey([0, 1, 2, 250, 251, 252])

        XCTAssertTrue(key.hasPrefix("sk-"))
        XCTAssertFalse(key.contains("+"))
        XCTAssertFalse(key.contains("/"))
        XCTAssertFalse(key.contains("="))
    }

    func testGatewayCredentialPlanSkipsCredentialsThatCannotServeRequests() {
        let routed = APIEndpointConfiguration(
            name: "Routed",
            source: .directHTTPS(originURL: URL(string: "https://routed.example")!),
            authentication: .bearer
        )
        let noAuthentication = APIEndpointConfiguration(
            name: "No authentication",
            source: .directHTTPS(originURL: URL(string: "https://public.example")!)
        )
        let unrouted = APIEndpointConfiguration(
            name: "Unrouted",
            source: .directHTTPS(originURL: URL(string: "https://unused.example")!),
            authentication: .bearer
        )
        let key = GatewayAPIKeyConfiguration(name: "Disabled by gateway policy")
        let configuration = ModelMoorConfiguration(
            endpoints: [routed, noAuthentication, unrouted],
            routes: [
                ModelRouteConfiguration(publicModel: "routed", endpointID: routed.id, upstreamModel: "one"),
                ModelRouteConfiguration(publicModel: "public", endpointID: noAuthentication.id, upstreamModel: "two")
            ],
            gateway: GatewayConfiguration(requiresAPIKey: false, apiKeys: [key])
        )

        let plan = GatewayCredentialAccessPlan(configuration: configuration)

        XCTAssertTrue(plan.gatewayAPIKeyIDs.isEmpty)
        XCTAssertEqual(plan.endpointIDs, [routed.id])
    }

    func testGatewayWithAuthenticationDisabledDoesNotTouchKeychain() throws {
        let store = KeychainTokenStore(
            service: "dev.modelmoor.tests.\(UUID().uuidString)",
            userInteraction: .disallow
        )
        let gateway = GatewayConfiguration(
            requiresAPIKey: false,
            apiKeys: [GatewayAPIKeyConfiguration(name: "Must remain unused")]
        )

        XCTAssertEqual(try store.enabledGatewayAPIKeys(for: gateway), [])
    }

    func testNoninteractiveKeychainQueryReturnsWithoutAuthenticationUI() throws {
        let store = KeychainTokenStore(
            service: "dev.modelmoor.tests.\(UUID().uuidString)",
            userInteraction: .disallow
        )

        XCTAssertNil(try store.token(for: UUID()))
    }

    func testEndpointKindsSeparateLLMAPIsFromOtherServices() {
        XCTAssertTrue(APIEndpointKind.openAICompatible.isLLMAPI)
        XCTAssertTrue(APIEndpointKind.ollama.isLLMAPI)
        XCTAssertFalse(APIEndpointKind.customHTTP.isLLMAPI)
    }

    func testLegacyGatewayConfigurationDecodesWithDefaultAPIKey() throws {
        let data = Data(#"{"enabled":true,"listenPort":17777}"#.utf8)
        let gateway = try JSONDecoder().decode(GatewayConfiguration.self, from: data)

        XCTAssertTrue(gateway.requiresAPIKey)
        XCTAssertEqual(gateway.apiKeys, [.defaultKey])
    }

    func testGatewayRequiresAtLeastOneEnabledAPIKeyOnlyWhenAuthenticationIsOn() throws {
        let disabledKey = GatewayAPIKeyConfiguration(name: "Automation", enabled: false)
        XCTAssertThrowsError(try GatewayConfiguration(apiKeys: [disabledKey]).validated())
        XCTAssertNoThrow(try GatewayConfiguration(requiresAPIKey: false, apiKeys: [disabledKey]).validated())
    }

    func testLocalMappingAndEndpointBuildReachableURLs() throws {
        let mapping = PortMappingConfiguration(
            listenPort: 18_888,
            destinationPort: 8_888
        )
        let endpoint = APIEndpointConfiguration(
            name: "Models",
            source: .sshMapping(mappingID: mapping.id, originScheme: .http)
        )

        XCTAssertEqual(
            try EndpointURLResolver.resolve(endpoint, mappings: [mapping.id: mapping]).absoluteString,
            "http://127.0.0.1:18888/v1"
        )
        XCTAssertEqual(
            try EndpointURLResolver.resolve(endpoint, path: endpoint.healthPath, mappings: [mapping.id: mapping]).absoluteString,
            "http://127.0.0.1:18888/v1/models"
        )
        XCTAssertNoThrow(try mapping.validated())
    }

    func testRemoteMappingIsInspectedAtLocalDestination() {
        let mapping = PortMappingConfiguration(
            direction: .remote,
            listenPort: 18_888,
            destinationHost: "127.0.0.1",
            destinationPort: 8_888
        )

        XCTAssertEqual(mapping.forwardingSpecification, "127.0.0.1:18888:127.0.0.1:8888")
    }

    func testDynamicMappingsUseListenerOnlySpecifications() throws {
        let dynamic = PortMappingConfiguration(
            name: "Local SOCKS",
            direction: .dynamic,
            listenPort: 1_080,
            destinationHost: "",
            destinationPort: 0
        )
        let reverseDynamic = PortMappingConfiguration(
            name: "Remote SOCKS",
            direction: .reverseDynamic,
            listenPort: 10_080,
            destinationHost: "",
            destinationPort: 0
        )

        XCTAssertEqual(dynamic.direction.sshFlag, "-D")
        XCTAssertEqual(dynamic.forwardingSpecification, "127.0.0.1:1080")
        XCTAssertTrue(dynamic.direction.listensLocally)
        XCTAssertNoThrow(try dynamic.validated())
        XCTAssertEqual(reverseDynamic.direction.sshFlag, "-R")
        XCTAssertEqual(reverseDynamic.forwardingSpecification, "127.0.0.1:10080")
        XCTAssertFalse(reverseDynamic.direction.listensLocally)
        XCTAssertNoThrow(try reverseDynamic.validated())
    }

    func testMappingsRejectNonLoopbackListeners() {
        for direction in PortForwardDirection.allCases {
            let mapping = PortMappingConfiguration(direction: direction, listenHost: "0.0.0.0")
            XCTAssertThrowsError(try mapping.validated())
        }
    }

    func testTunnelRejectsSSHOptionInjection() {
        let tunnel = TunnelConfiguration(name: "Unsafe", sshHost: "-oProxyCommand=bad")
        XCTAssertThrowsError(try tunnel.validated())
    }

    func testConfigurationRejectsDuplicateLocalListenersAcrossMoorings() {
        let configuration = ModelMoorConfiguration(tunnels: [
            TunnelConfiguration(name: "One", sshHost: "one", mappings: [
                PortMappingConfiguration(name: "API", listenPort: 19_001)
            ]),
            TunnelConfiguration(name: "Two", sshHost: "two", mappings: [
                PortMappingConfiguration(name: "API", listenPort: 19_001)
            ])
        ])

        XCTAssertThrowsError(try configuration.validated())
    }

    func testRemoteListenersAreScopedToSSHTarget() {
        let mappingOne = PortMappingConfiguration(name: "API", direction: .remote, listenPort: 19_001)
        let mappingTwo = PortMappingConfiguration(name: "API", direction: .remote, listenPort: 19_001)
        let configuration = ModelMoorConfiguration(tunnels: [
            TunnelConfiguration(name: "One", sshHost: "one", mappings: [mappingOne]),
            TunnelConfiguration(name: "Two", sshHost: "two", mappings: [mappingTwo])
        ])

        XCTAssertNoThrow(try configuration.validated())
    }

    func testSSHCommandsUseDedicatedMasterAndIsolatedForwardControls() {
        let tunnel = TunnelConfiguration(
            name: "DGX Spark",
            sshHost: "localhost",
            mappings: [
                PortMappingConfiguration(name: "API", listenPort: 18_888, destinationPort: 8_888),
                PortMappingConfiguration(
                    name: "Reverse UI",
                    direction: .remote,
                    listenPort: 19_999,
                    destinationPort: 3_000
                ),
                PortMappingConfiguration(
                    name: "Local SOCKS",
                    direction: .dynamic,
                    listenPort: 1_080
                ),
                PortMappingConfiguration(
                    name: "Remote SOCKS",
                    direction: .reverseDynamic,
                    listenPort: 10_080
                ),
                PortMappingConfiguration(name: "Disabled", listenPort: 20_000, enabled: false)
            ],
            connectTimeoutSeconds: 23,
            keepAliveIntervalSeconds: 41,
            keepAliveFailureCount: 5
        )
        let builder = SSHCommandBuilder(
            controlDirectoryURL: URL(fileURLWithPath: "/tmp/modelmoor-command-tests", isDirectory: true)
        )
        let command = builder.command(for: tunnel)
        let forward = builder.controlCommand(.forward, for: tunnel)
        let cancel = builder.controlCommand(.cancel, for: tunnel)

        XCTAssertEqual(command.executableURL.path, "/usr/bin/ssh")
        XCTAssertTrue(command.arguments.contains("-M"))
        XCTAssertTrue(command.arguments.contains("BatchMode=yes"))
        XCTAssertTrue(command.arguments.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(command.arguments.contains("ClearAllForwardings=yes"))
        XCTAssertTrue(command.arguments.contains("ControlPersist=no"))
        XCTAssertTrue(command.arguments.contains("ConnectTimeout=23"))
        XCTAssertFalse(command.arguments.contains("-L"))
        XCTAssertFalse(command.arguments.contains("-R"))
        XCTAssertFalse(command.arguments.contains("-D"))
        XCTAssertEqual(command.arguments.last, "localhost")

        XCTAssertTrue(forward.arguments.starts(with: [
            "-F", "/dev/null",
            "-S", builder.controlPath(for: tunnel),
            "-O", "forward"
        ]))
        XCTAssertEqual(forward.arguments.filter { $0 == "-L" }.count, 1)
        XCTAssertEqual(forward.arguments.filter { $0 == "-R" }.count, 2)
        XCTAssertEqual(forward.arguments.filter { $0 == "-D" }.count, 1)
        XCTAssertTrue(forward.arguments.contains("127.0.0.1:18888:127.0.0.1:8888"))
        XCTAssertTrue(forward.arguments.contains("127.0.0.1:19999:127.0.0.1:3000"))
        XCTAssertTrue(forward.arguments.contains("127.0.0.1:1080"))
        XCTAssertTrue(forward.arguments.contains("127.0.0.1:10080"))
        XCTAssertFalse(forward.arguments.contains("127.0.0.1:20000:127.0.0.1:8888"))
        XCTAssertTrue(cancel.arguments.contains("cancel"))
        XCTAssertEqual(cancel.arguments.filter { $0 == "-L" }.count, 1)
        XCTAssertEqual(cancel.arguments.filter { $0 == "-R" }.count, 2)
        XCTAssertEqual(cancel.arguments.filter { $0 == "-D" }.count, 1)
    }

    func testDefaultControlPathLeavesRoomForOpenSSHBindingSuffix() {
        let tunnel = TunnelConfiguration(name: "Socket path", sshHost: "socket.test")
        let pathLength = SSHCommandBuilder().controlPath(for: tunnel).utf8.count

        // macOS sockaddr_un.sun_path allows 104 bytes including NUL. OpenSSH
        // appends a dot plus 16 random characters while binding the socket.
        XCTAssertLessThanOrEqual(pathLength, 86)
    }

    func testSSHProcessRunCompletesRepeatedImmediateCommands() async throws {
        let command = SSHCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: []
        )

        for _ in 0..<100 {
            let result = try await SSHProcess.run(command)
            XCTAssertEqual(result.terminationStatus, 0)
        }
    }

    func testSupervisedSSHProcessStopsWhenItsOwnerExits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorWatchdog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let childPIDURL = directory.appendingPathComponent("child.pid")

        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        owner.arguments = ["0.5"]
        try owner.run()

        let command = SSHCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "echo $$ > \"$1\"; exec /bin/sleep 30",
                "modelmoor-watchdog-test",
                childPIDURL.path
            ]
        )
        let clock = ContinuousClock()
        let startedAt = clock.now
        let process = try SSHProcess.launchSupervised(command, ownerPID: owner.processIdentifier)
        let status = await process.waitForExit()

        XCTAssertEqual(status, 0)
        XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(3))
        let childPID = try XCTUnwrap(Int32(String(contentsOf: childPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testTunnelOwnsMasterForwardingLifecycleWithoutRetryingAfterCodeZero() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableURL = directory.appendingPathComponent("fake-ssh")
        let eventsURL = directory.appendingPathComponent("events")
        let script = """
        #!/bin/sh
        control=""
        operation=""
        master=0
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -M) master=1; shift ;;
            -S) control="$2"; shift 2 ;;
            -O) operation="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        ready="${control}.ready"
        case "$operation" in
          check) [ -f "$ready" ]; exit $? ;;
          forward) echo forward >> "\(eventsURL.path)"; exit 0 ;;
          cancel) echo cancel >> "\(eventsURL.path)"; exit 0 ;;
          exit)
            if [ -f "$ready" ]; then
              echo exit >> "\(eventsURL.path)"
              rm -f "$ready"
            fi
            exit 0
            ;;
        esac
        if [ "$master" -eq 1 ]; then
          touch "$ready"
          echo master >> "\(eventsURL.path)"
          while [ -f "$ready" ]; do sleep 0.05; done
          exit 0
        fi
        exit 0
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let tunnel = TunnelConfiguration(
            name: "Lifecycle",
            sshHost: "lifecycle.test",
            mappings: [PortMappingConfiguration(listenPort: 18_889)]
        )
        let recorder = TunnelStatusRecorder()
        let service = TunnelService(commandBuilder: SSHCommandBuilder(
            executableURL: executableURL,
            controlDirectoryURL: directory.appendingPathComponent("control", isDirectory: true)
        ), localPortPreflight: { _ in }) { status in
            Task { await recorder.append(status) }
        }

        await service.setRuntimeAvailable(false, reason: "Waiting for test network")
        await service.start(tunnel)
        let waiting = await waitForPhase(.waitingForNetwork, in: recorder)
        XCTAssertTrue(waiting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: eventsURL.path))
        await service.setRuntimeAvailable(true)
        let connected = await waitForPhase(.connected, in: recorder)
        await service.stop(tunnel.id)

        let phases = await recorder.phases
        let events = (try? String(contentsOf: eventsURL, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
        XCTAssertTrue(connected)
        XCTAssertFalse(phases.contains(.waitingToRetry))
        XCTAssertEqual(events, ["master", "forward", "cancel", "exit"])
    }

    func testReconcileRestartsOnlyTheChangedTunnelMaster() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorReconcile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executableURL = directory.appendingPathComponent("fake-ssh")
        let eventsURL = directory.appendingPathComponent("events")
        try writeFakeSSH(executableURL: executableURL, eventsURL: eventsURL)
        let builder = SSHCommandBuilder(
            executableURL: executableURL,
            controlDirectoryURL: directory.appendingPathComponent("control", isDirectory: true)
        )
        let first = TunnelConfiguration(
            name: "First",
            sshHost: "first.test",
            mappings: [PortMappingConfiguration(listenPort: 18_901)]
        )
        let second = TunnelConfiguration(
            name: "Second",
            sshHost: "second.test",
            mappings: [PortMappingConfiguration(listenPort: 18_902)]
        )
        let recorder = TunnelStatusRecorder()
        let service = TunnelService(commandBuilder: builder, localPortPreflight: { _ in }) { status in
            Task { await recorder.append(status) }
        }

        await service.reconcile([first, second])
        let firstConnected = await waitForPhase(.connected, tunnelID: first.id, in: recorder)
        let secondConnected = await waitForPhase(.connected, tunnelID: second.id, in: recorder)
        XCTAssertTrue(firstConnected)
        XCTAssertTrue(secondConnected)
        var changedFirst = first
        changedFirst.name = "First edited"
        await service.reconcile([changedFirst, second])
        let firstReconnected = await waitForPhase(.connected, tunnelID: first.id, minimumCount: 2, in: recorder)
        XCTAssertTrue(firstReconnected)
        await service.stopAll()

        let events = (try? String(contentsOf: eventsURL, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
        XCTAssertEqual(events.filter { $0 == "master:\(builder.controlPath(for: first))" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "master:\(builder.controlPath(for: second))" }.count, 1)
    }

    func testUnexpectedMasterExitReconnectsWithoutUserAction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorRemoteRestart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executableURL = directory.appendingPathComponent("fake-ssh")
        let eventsURL = directory.appendingPathComponent("events")
        try writeFakeSSH(executableURL: executableURL, eventsURL: eventsURL, exitMasterAfter: 0.15)
        let tunnel = TunnelConfiguration(
            name: "Remote restart",
            sshHost: "restart.test",
            mappings: [PortMappingConfiguration(listenPort: 18_903)],
            reconnectInitialDelaySeconds: 1,
            reconnectMaximumDelaySeconds: 1
        )
        let recorder = TunnelStatusRecorder()
        let service = TunnelService(commandBuilder: SSHCommandBuilder(
            executableURL: executableURL,
            controlDirectoryURL: directory.appendingPathComponent("control", isDirectory: true)
        ), localPortPreflight: { _ in }) { status in
            Task { await recorder.append(status) }
        }

        await service.start(tunnel)
        let reconnected = await waitForPhase(
            .connected,
            tunnelID: tunnel.id,
            minimumCount: 2,
            in: recorder,
            attempts: 140
        )
        XCTAssertTrue(reconnected)
        await service.stopAll()
        let statuses = await recorder.statuses
        XCTAssertTrue(statuses.contains { $0.tunnelID == tunnel.id && $0.phase == .waitingToRetry })
    }

    func testRemoteForwardConflictHasActionableFailureMessage() {
        let tunnel = TunnelConfiguration(
            name: "DGX Spark",
            sshHost: "localhost",
            mappings: [
                PortMappingConfiguration(
                    name: "Spark Dash",
                    direction: .remote,
                    listenPort: 5_555,
                    destinationPort: 5_555
                )
            ]
        )
        let errorText = """
        mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 5555
        muxclient: master forward request failed
        """

        XCTAssertEqual(
            SSHFailureDetail.message(for: tunnel, errorText: errorText),
            "Remote port 127.0.0.1:5555 is already in use on localhost. Choose another remote listen port or stop the existing listener."
        )
    }

    func testReconnectPolicyCapsDelay() {
        let policy = ReconnectPolicy(initialDelay: .seconds(1), maximumDelay: .seconds(30))
        XCTAssertEqual(policy.delay(afterAttempt: 1), .seconds(1))
        XCTAssertEqual(policy.delay(afterAttempt: 3), .seconds(4))
        XCTAssertEqual(policy.delay(afterAttempt: 99), .seconds(30))
        XCTAssertEqual(policy.jitteredDelay(afterAttempt: 1, randomUnit: 0), .milliseconds(800))
        XCTAssertEqual(policy.jitteredDelay(afterAttempt: 1, randomUnit: 0.5), .seconds(1))
        XCTAssertEqual(policy.jitteredDelay(afterAttempt: 1, randomUnit: 1), .milliseconds(1_200))
    }

    func testSSHFailuresAreClassifiedForRetryPolicy() {
        let tunnel = TunnelConfiguration(name: "Lab", sshHost: "lab.example")
        XCTAssertEqual(
            SSHFailureDetail.category(for: tunnel, errorText: "Permission denied (publickey)."),
            .sshAuthentication
        )
        XCTAssertEqual(
            SSHFailureDetail.category(for: tunnel, errorText: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"),
            .hostKey
        )
        XCTAssertEqual(
            SSHFailureDetail.category(for: tunnel, errorText: "ssh: Could not resolve hostname lab.example"),
            .dns
        )
    }

    func testOccupiedLocalPortFailsPreflightWithoutLaunchingSSH() async throws {
        let port = 54_321
        let tunnel = TunnelConfiguration(
            name: "Occupied",
            sshHost: "unused.example",
            mappings: [PortMappingConfiguration(listenPort: port)],
            autoReconnect: false
        )
        let recorder = TunnelStatusRecorder()
        let service = TunnelService(localPortPreflight: { _ in
            throw TunnelPreflightFailure(
                detail: "Local port 127.0.0.1:\(port) is already in use.",
                category: .localPortInUse
            )
        }) { status in
            Task { await recorder.append(status) }
        }

        await service.start(tunnel)
        let reachedFailure = await waitForPhase(.failed, in: recorder)
        XCTAssertTrue(reachedFailure)
        let failure = await recorder.statuses.last(where: { $0.phase == .failed })
        XCTAssertEqual(failure?.failureCategory, .localPortInUse)
        XCTAssertTrue(failure?.message.contains("already in use") == true)
        await service.stopAll()
    }

    func testConfigurationStoreRoundTripUsesSchemaTwo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(fileURL: directory.appendingPathComponent("config.json"))
        let expected = ModelMoorConfiguration(tunnels: [
            TunnelConfiguration(name: "Lab", sshHost: "lab-host")
        ])

        try await store.save(expected)
        let loaded = try await store.load()

        XCTAssertEqual(loaded, expected)
        XCTAssertEqual(loaded.schemaVersion, 2)
        let saved = try String(contentsOf: await store.fileURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("\"connectOnLaunch\""))
        XCTAssertTrue(saved.contains("\"endpoints\""))
        XCTAssertTrue(saved.contains("\"routes\""))
        XCTAssertTrue(saved.contains("\"gateway\""))
        XCTAssertFalse(saved.contains("\"probePath\""))
    }

    func testConfigurationStorePreparesCloudEndpointsOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorRecommendedEndpoints-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("config.json")
        let store = ConfigurationStore(fileURL: fileURL)

        var loaded = try await store.load()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(loaded.hasPreparedRecommendedEndpoints)
        XCTAssertEqual(
            loaded.endpoints.map(\.name),
            ["Moonshot / Kimi Open Platform", "DeepSeek"]
        )
        XCTAssertEqual(loaded.endpoints.map(\.enabled), [false, false])
        XCTAssertEqual(loaded.endpoints.map(\.authentication), [.bearer, .bearer])
        XCTAssertEqual(
            loaded.endpoints.compactMap { endpoint -> String? in
                guard case let .directHTTPS(origin) = endpoint.source else { return nil }
                return origin.absoluteString + endpoint.basePath
            },
            ["https://api.moonshot.cn/v1", "https://api.deepseek.com"]
        )

        loaded.endpoints.removeFirst()
        try await store.save(loaded)
        let reloaded = try await store.load()

        XCTAssertEqual(reloaded.endpoints.map(\.name), ["DeepSeek"])
    }

    func testConfigurationStoreMigratesSchemaOneOnceAndPreservesIdentifiers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorOldSchema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("config.json")
        let tunnelID = UUID()
        let mappingID = UUID()
        let legacy = Data("""
        {
          "schemaVersion": 1,
          "tunnels": [{
            "id": "\(tunnelID.uuidString)",
            "name": "Legacy Lab",
            "sshHost": "legacy.lab",
            "mappings": [{
              "id": "\(mappingID.uuidString)",
              "name": "Models",
              "direction": "local",
              "listenHost": "127.0.0.1",
              "listenPort": 18888,
              "destinationHost": "127.0.0.1",
              "destinationPort": 8888,
              "scheme": "https",
              "probePath": "/v1/models",
              "enabled": true
            }],
            "enabled": false,
            "autoReconnect": true,
            "reconnectInitialDelaySeconds": 1,
            "reconnectMaximumDelaySeconds": 30,
            "connectTimeoutSeconds": 10,
            "keepAliveIntervalSeconds": 15,
            "keepAliveFailureCount": 3
          }]
        }
        """.utf8)
        try legacy.write(to: fileURL)
        let migratedWithCredential = try ConfigurationMigration.migrateV1(
            legacy,
            endpointHasCredential: { $0 == mappingID }
        )
        XCTAssertEqual(
            migratedWithCredential.endpoints.first?.authentication,
            APIEndpointAuthentication.bearer
        )

        let store = ConfigurationStore(fileURL: fileURL, endpointCredentialLookup: { _ in nil })
        let loaded = try await store.load()

        XCTAssertEqual(loaded.schemaVersion, 2)
        XCTAssertEqual(loaded.tunnels.first?.id, tunnelID)
        XCTAssertEqual(loaded.tunnels.first?.mappings.first?.id, mappingID)
        XCTAssertEqual(loaded.tunnels.first?.connectOnLaunch, false)
        XCTAssertEqual(loaded.endpoints.first?.id, mappingID)
        XCTAssertEqual(loaded.endpoints.first?.kind, .openAICompatible)
        XCTAssertEqual(loaded.endpoints.first?.basePath, "/v1")
        XCTAssertEqual(loaded.endpoints.first?.authentication, APIEndpointAuthentication.none)
        let mappings = Dictionary(uniqueKeysWithValues: loaded.tunnels.flatMap(\.mappings).map { ($0.id, $0) })
        XCTAssertEqual(
            try loaded.endpoints.first.map { try EndpointURLResolver.resolve($0, mappings: mappings) }?.absoluteString,
            "https://127.0.0.1:18888/v1"
        )
        XCTAssertTrue(loaded.routes.isEmpty)
        XCTAssertFalse(loaded.gateway.enabled)

        let backupURL = directory.appendingPathComponent("config.json.v1.backup")
        XCTAssertEqual(try Data(contentsOf: backupURL), legacy)
        let backupAfterFirstLoad = try Data(contentsOf: backupURL)
        _ = try await store.load()
        XCTAssertEqual(try Data(contentsOf: backupURL), backupAfterFirstLoad)
    }

    func testConfigurationStoreRepairsOnlyCredentiallessLegacySchemaTwoEndpoints() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorLegacyAuthRepair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("config.json")
        let openMapping = PortMappingConfiguration(name: "Open")
        let protectedMapping = PortMappingConfiguration(name: "Protected", listenPort: 18_889)
        let tunnel = TunnelConfiguration(
            name: "Legacy Lab",
            sshHost: "legacy.lab",
            mappings: [openMapping, protectedMapping]
        )
        let openEndpoint = APIEndpointConfiguration(
            id: openMapping.id,
            name: "Open API",
            source: .sshMapping(mappingID: openMapping.id, originScheme: .http),
            authentication: .bearer
        )
        let protectedEndpoint = APIEndpointConfiguration(
            id: protectedMapping.id,
            name: "Protected API",
            source: .sshMapping(mappingID: protectedMapping.id, originScheme: .http),
            authentication: .bearer
        )
        let original = ModelMoorConfiguration(
            tunnels: [tunnel],
            endpoints: [openEndpoint, protectedEndpoint]
        )
        let writer = ConfigurationStore(fileURL: fileURL)
        try await writer.save(original)
        let store = ConfigurationStore(fileURL: fileURL, endpointCredentialLookup: {
            $0 == protectedEndpoint.id ? "saved-secret" : nil
        })

        let loaded = try await store.load()

        XCTAssertEqual(loaded.endpoints[0].authentication, .none)
        XCTAssertEqual(loaded.endpoints[1].authentication, .bearer)
        let persisted = try JSONDecoder().decode(
            ModelMoorConfiguration.self,
            from: Data(contentsOf: fileURL)
        )
        XCTAssertEqual(persisted.endpoints, loaded.endpoints)
    }

    func testFutureSchemaIsReadableAsAnErrorAndCannotBeOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorFutureSchema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("config.json")
        let future = Data("{\"schemaVersion\":99,\"tunnels\":[{\"future\":true}]}".utf8)
        try future.write(to: fileURL)
        let store = ConfigurationStore(fileURL: fileURL)

        await XCTAssertThrowsErrorAsync(try await store.load()) { error in
            XCTAssertEqual(error as? ConfigurationError, .unsupportedSchema(99))
        }
        await XCTAssertThrowsErrorAsync(try await store.save(ModelMoorConfiguration())) { error in
            XCTAssertEqual(error as? ConfigurationError, .unsupportedSchema(99))
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), future)
    }

    func testInvalidSavePreservesLastValidConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorAtomicSave-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("config.json")
        let store = ConfigurationStore(fileURL: fileURL)
        try await store.save(ModelMoorConfiguration(tunnels: [
            TunnelConfiguration(name: "Valid", sshHost: "valid.lab")
        ]))
        let validData = try Data(contentsOf: fileURL)

        await XCTAssertThrowsErrorAsync(try await store.save(ModelMoorConfiguration(tunnels: [
            TunnelConfiguration(name: "Duplicate", sshHost: "one.lab"),
            TunnelConfiguration(name: "Duplicate", sshHost: "two.lab", mappings: [
                PortMappingConfiguration(listenPort: 19_999)
            ])
        ])))

        XCTAssertEqual(try Data(contentsOf: fileURL), validData)
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.tunnels.first?.name, "Valid")
    }

    func testRuntimeOwnershipRejectsASecondOwnerAndCanBeReacquired() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorOwner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("runtime.lock")

        var first: RuntimeOwnership? = try RuntimeOwnership.acquire(lockFileURL: lockURL, owner: "first")
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try RuntimeOwnership.acquire(lockFileURL: lockURL, owner: "second")) { error in
            guard case let RuntimeOwnershipError.alreadyOwned(owner) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(owner?.contains("owner=first") == true)
        }
        first = nil
        XCTAssertNoThrow(try RuntimeOwnership.acquire(lockFileURL: lockURL, owner: "third"))
    }

    func testDirectEndpointSplitsOriginAndBasePath() throws {
        let parsed = try EndpointURLResolver.parseDirectBaseURL("https://api.example.com/openai/v1/")
        XCTAssertEqual(parsed.origin.absoluteString, "https://api.example.com")
        XCTAssertEqual(parsed.basePath, "/openai/v1")

        let endpoint = APIEndpointConfiguration(
            name: "Commercial",
            source: .directHTTPS(originURL: parsed.origin),
            basePath: parsed.basePath,
            healthPath: "/openai/v1/models",
            modelListPath: "/openai/v1/models",
            authentication: .bearer
        )
        XCTAssertEqual(
            try EndpointURLResolver.resolve(endpoint, mappings: [:]).absoluteString,
            "https://api.example.com/openai/v1"
        )
        XCTAssertThrowsError(try EndpointURLResolver.parseDirectBaseURL("http://api.example.com/v1"))
    }

    func testDeepSeekPresetUsesDirectHTTPSWithoutPersistingASecret() throws {
        let endpoint = APIEndpointConfiguration.deepSeek()
        XCTAssertEqual(try EndpointURLResolver.resolve(endpoint, mappings: [:]).absoluteString, "https://api.deepseek.com")
        XCTAssertEqual(endpoint.authentication, .bearer)
        let json = String(decoding: try JSONEncoder().encode(endpoint), as: UTF8.self)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("api key"))
        XCTAssertFalse(json.contains("secret"))
    }

    func testLegacyEndpointCredentialDecodesAsDefaultActiveAPIKey() throws {
        let endpointID = UUID()
        let data = Data("""
        {
          "id": "\(endpointID.uuidString)",
          "name": "Legacy API",
          "source": {"type": "directHTTPS", "originURL": "https://legacy.example"},
          "kind": "openAICompatible",
          "basePath": "/v1",
          "healthPath": "/v1/models",
          "modelListPath": "/v1/models",
          "pollIntervalSeconds": 30,
          "authentication": {"type": "bearer"},
          "enabled": true
        }
        """.utf8)

        let endpoint = try JSONDecoder().decode(APIEndpointConfiguration.self, from: data)

        XCTAssertEqual(endpoint.apiKeys, [EndpointAPIKeyConfiguration(id: endpointID, name: "Default key")])
        XCTAssertEqual(endpoint.activeAPIKeyID, endpointID)
    }

    func testEndpointSecretsUseTheSelectedAPIKey() throws {
        let store = KeychainTokenStore(service: "dev.modelmoor.tests.\(UUID().uuidString)")
        let first = EndpointAPIKeyConfiguration(name: "Personal")
        let second = EndpointAPIKeyConfiguration(name: "Team")
        var endpoint = APIEndpointConfiguration(
            name: "Cloud API",
            source: .directHTTPS(originURL: URL(string: "https://api.example.com")!),
            authentication: .bearer,
            apiKeys: [first, second],
            activeAPIKeyID: second.id
        )
        endpoint.enabled = true
        let configuration = ModelMoorConfiguration(
            endpoints: [endpoint],
            routes: [ModelRouteConfiguration(
                publicModel: "example",
                endpointID: endpoint.id,
                upstreamModel: "example"
            )]
        )
        defer {
            try? store.setToken(nil, for: first.id)
            try? store.setToken(nil, for: second.id)
        }
        try store.setToken("first-secret", for: first.id)
        try store.setToken("second-secret", for: second.id)

        XCTAssertEqual(store.endpointSecrets(for: configuration)[endpoint.id], "second-secret")
    }

    func testCustomAuthenticationHeaderRejectsReservedAndInvalidNames() {
        func endpoint(header: String) -> APIEndpointConfiguration {
            APIEndpointConfiguration(
                name: "Custom auth",
                source: .directHTTPS(originURL: URL(string: "https://api.example.com")!),
                authentication: .header(name: header)
            )
        }

        XCTAssertNoThrow(try ModelMoorConfiguration(endpoints: [endpoint(header: "X-API-Key")]).validated())
        XCTAssertThrowsError(try ModelMoorConfiguration(endpoints: [endpoint(header: "Authorization")]).validated())
        XCTAssertThrowsError(try ModelMoorConfiguration(endpoints: [endpoint(header: "Content-Length")]).validated())
        XCTAssertThrowsError(try ModelMoorConfiguration(endpoints: [endpoint(header: "Bad Header")]).validated())
        XCTAssertThrowsError(try ModelMoorConfiguration(endpoints: [endpoint(header: "X-Bad(Header)")]).validated())
    }

    func testRoutesRequireUniquePublicModelsAndOpenAIEndpoints() throws {
        let endpoint = APIEndpointConfiguration.deepSeek()
        let route = ModelRouteConfiguration(
            publicModel: "fast",
            endpointID: endpoint.id,
            upstreamModel: "deepseek-v4-flash"
        )
        XCTAssertNoThrow(try ModelMoorConfiguration(endpoints: [endpoint], routes: [route]).validated())
        XCTAssertThrowsError(try ModelMoorConfiguration(endpoints: [endpoint], routes: [route, route]).validated())

        var ollama = endpoint
        ollama.kind = .ollama
        XCTAssertThrowsError(try ModelMoorConfiguration(endpoints: [ollama], routes: [route]).validated())
    }

    func testMappingDeletionCascadesOnlyItsEndpointAndRoutes() throws {
        let removedMapping = PortMappingConfiguration(name: "Removed", listenPort: 18_881)
        let keptMapping = PortMappingConfiguration(name: "Kept", listenPort: 18_882)
        let tunnel = TunnelConfiguration(
            name: "Lab",
            sshHost: "lab.example",
            mappings: [removedMapping, keptMapping]
        )
        let removedEndpoint = APIEndpointConfiguration(
            name: "Removed endpoint",
            source: .sshMapping(mappingID: removedMapping.id, originScheme: .http)
        )
        let keptEndpoint = APIEndpointConfiguration(
            name: "Kept endpoint",
            source: .sshMapping(mappingID: keptMapping.id, originScheme: .http)
        )
        let removedRoute = ModelRouteConfiguration(
            publicModel: "removed",
            endpointID: removedEndpoint.id,
            upstreamModel: "upstream-removed"
        )
        let keptRoute = ModelRouteConfiguration(
            publicModel: "kept",
            endpointID: keptEndpoint.id,
            upstreamModel: "upstream-kept"
        )
        let configuration = ModelMoorConfiguration(
            tunnels: [tunnel],
            endpoints: [removedEndpoint, keptEndpoint],
            routes: [removedRoute, keptRoute]
        )

        let result = try ConfigurationCascade.removingMapping(
            removedMapping.id,
            fromTunnel: tunnel.id,
            in: configuration
        )

        XCTAssertEqual(result.removedMappingIDs, [removedMapping.id])
        XCTAssertEqual(result.removedEndpointIDs, [removedEndpoint.id])
        XCTAssertEqual(result.removedRouteIDs, [removedRoute.id])
        XCTAssertEqual(result.configuration.tunnels.first?.mappings.map(\.id), [keptMapping.id])
        XCTAssertEqual(result.configuration.endpoints.map(\.id), [keptEndpoint.id])
        XCTAssertEqual(result.configuration.routes.map(\.id), [keptRoute.id])
    }

    func testDeletionRestoresCredentialWhenConfigurationSaveFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorCascadeRollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("config.json")
        try Data("{\"schemaVersion\":99,\"tunnels\":[]}".utf8).write(to: fileURL)
        let mapping = PortMappingConfiguration()
        let tunnel = TunnelConfiguration(name: "Lab", sshHost: "lab", mappings: [mapping])
        let endpoint = APIEndpointConfiguration(
            name: "Lab API",
            source: .sshMapping(mappingID: mapping.id, originScheme: .http)
        )
        let configuration = ModelMoorConfiguration(tunnels: [tunnel], endpoints: [endpoint])
        let secrets = FakeEndpointSecretStore(values: [endpoint.id: "super-secret"])
        let coordinator = ConfigurationDeletionCoordinator(
            store: ConfigurationStore(fileURL: fileURL),
            secretStore: secrets
        )

        await XCTAssertThrowsErrorAsync(try await coordinator.removeTunnel(tunnel.id, from: configuration))

        XCTAssertEqual(try secrets.token(for: endpoint.id), "super-secret")
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("{\"schemaVersion\":99,\"tunnels\":[]}".utf8))
    }

    func testEndpointCreationRestoresCredentialWhenConfigurationSaveFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorEndpointRollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("config.json")
        let futureConfiguration = Data("{\"schemaVersion\":99,\"tunnels\":[]}".utf8)
        try futureConfiguration.write(to: fileURL)
        let endpoint = APIEndpointConfiguration.deepSeek()
        let secrets = FakeEndpointSecretStore()
        let coordinator = ConfigurationDeletionCoordinator(
            store: ConfigurationStore(fileURL: fileURL),
            secretStore: secrets
        )

        await XCTAssertThrowsErrorAsync(
            try await coordinator.addEndpoint(
                endpoint,
                secret: "must-not-be-orphaned",
                to: ModelMoorConfiguration()
            )
        )

        XCTAssertNil(try secrets.token(for: endpoint.id))
        XCTAssertEqual(try Data(contentsOf: fileURL), futureConfiguration)
    }

    func testDiagnosticLogIsBoundedAndRedactsSecretsAndHomePaths() async {
        let subject = DiagnosticSubject.mooring(UUID())
        let log = DiagnosticLog(capacityPerSubject: 2, homeDirectory: "/Users/private-user")
        await log.append(
            subject: subject,
            severity: .info,
            category: "first",
            summary: "discarded"
        )
        await log.append(
            subject: subject,
            severity: .warning,
            category: "auth",
            summary: "Authorization: Bearer visible-token at /Users/private-user/.ssh/config\nnext"
        )
        await log.append(
            subject: subject,
            severity: .error,
            category: "secret",
            summary: "upstream key=explicit-secret",
            secrets: ["explicit-secret"]
        )

        let events = await log.events(for: subject)
        let summary = await log.summary()
        XCTAssertEqual(events.count, 2)
        XCTAssertFalse(summary.contains("discarded"))
        XCTAssertFalse(summary.contains("visible-token"))
        XCTAssertFalse(summary.contains("explicit-secret"))
        XCTAssertFalse(summary.contains("/Users/private-user"))
        XCTAssertTrue(summary.contains("<redacted>"))
        XCTAssertTrue(summary.contains("~/.ssh/config next"))
    }

    func testEnvironmentCanOverrideConfigurationPath() {
        let url = ConfigurationStore.defaultURL(environment: [
            "MODELMOOR_CONFIG": "/tmp/modelmoor-test-config.json"
        ])
        XCTAssertEqual(url.path, "/tmp/modelmoor-test-config.json")
    }

    func testOpenAIModelListDecoding() throws {
        let data = Data("""
        {
          "object": "list",
          "data": [
            {"id":"qwen3","object":"model","created":1787000000,"owned_by":"vllm"},
            {"id":"gpt-oss-120b","object":"model","owned_by":"local"}
          ]
        }
        """.utf8)

        let models = try APIInspector.decodeModels(from: data)

        XCTAssertEqual(models.map(\.id), ["qwen3", "gpt-oss-120b"])
        XCTAssertEqual(models.first?.ownedBy, "vllm")
    }

    func testSSHConfigScannerFollowsIncludesAndSkipsWildcards() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorSSHScanner-\(UUID().uuidString)", isDirectory: true)
        let includeDirectory = directory.appendingPathComponent("config.d", isDirectory: true)
        try FileManager.default.createDirectory(at: includeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("""
        Include config.d/*.conf
        Host direct.lab
          HostName 192.0.2.8
        Host *.wildcard.lab
          User ignored
        """.utf8).write(to: directory.appendingPathComponent("config"))
        try Data("""
        Host jump.lab compute.lab
          ProxyJump direct.lab
        """.utf8).write(to: includeDirectory.appendingPathComponent("lab.conf"))

        let targets = try SSHConfigScanner(
            rootConfigURL: directory.appendingPathComponent("config")
        ).discoverTargets()

        XCTAssertEqual(targets.map(\.alias), ["compute.lab", "direct.lab", "jump.lab"])
    }

    func testTokenUsageStoreAggregatesRollingWindowsAndPersists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorUsage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("usage.jsonl")
        let store = TokenUsageStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        _ = try await store.record(tokens: 60, at: now.addingTimeInterval(-31 * 24 * 60 * 60))
        _ = try await store.record(tokens: 50, at: now.addingTimeInterval(-29 * 24 * 60 * 60))
        _ = try await store.record(tokens: 40, at: now.addingTimeInterval(-2 * 24 * 60 * 60))
        _ = try await store.record(tokens: 30, at: now.addingTimeInterval(-2 * 60 * 60))
        _ = try await store.record(tokens: 20, at: now.addingTimeInterval(-30 * 60))
        let snapshot = try await store.record(tokens: 10, at: now.addingTimeInterval(-30))

        XCTAssertEqual(snapshot.lastMinute, 10)
        XCTAssertEqual(snapshot.lastHour, 30)
        XCTAssertEqual(snapshot.lastDay, 60)
        XCTAssertEqual(snapshot.last30Days, 150)

        let reloaded = try await TokenUsageStore(fileURL: fileURL).snapshot(now: now)
        XCTAssertEqual(reloaded, snapshot)
        let saved = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(saved.contains("prompt"))
        XCTAssertFalse(saved.contains("response"))
    }

    func testUsageHistoryPathCanBeOverridden() {
        let url = TokenUsageStore.defaultURL(environment: [
            "MODELMOOR_USAGE": "/tmp/modelmoor-test-usage.jsonl"
        ])
        XCTAssertEqual(url.path, "/tmp/modelmoor-test-usage.jsonl")
    }

    func testTokenUsageReportBucketsAndFiltersRoutesAndEndpoints() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoorUsageReport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("usage.jsonl")
        let store = TokenUsageStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let routeA = UUID()
        let routeB = UUID()
        let endpointA = UUID()
        let endpointB = UUID()

        _ = try await store.record(
            tokens: 100,
            routeID: routeA,
            endpointID: endpointA,
            at: now.addingTimeInterval(-50 * 60)
        )
        _ = try await store.record(
            tokens: 200,
            routeID: routeA,
            endpointID: endpointA,
            at: now.addingTimeInterval(-10 * 60)
        )
        _ = try await store.record(
            tokens: 50,
            routeID: routeB,
            endpointID: endpointB,
            at: now.addingTimeInterval(-5 * 60)
        )

        let report = try await store.report(
            from: now.addingTimeInterval(-60 * 60),
            to: now,
            bucketInterval: 5 * 60
        )
        XCTAssertEqual(report.totalTokens, 350)
        XCTAssertEqual(report.requestCount, 3)
        XCTAssertEqual(report.series.map(\.tokens).reduce(0, +), 350)
        XCTAssertEqual(report.breakdowns.map(\.tokens), [300, 50])

        let routeReport = try await store.report(
            from: now.addingTimeInterval(-60 * 60),
            to: now,
            bucketInterval: 5 * 60,
            routeID: routeA
        )
        XCTAssertEqual(routeReport.totalTokens, 300)
        XCTAssertEqual(routeReport.requestCount, 2)
        XCTAssertEqual(routeReport.breakdowns.first?.routeID, routeA)
        XCTAssertEqual(routeReport.breakdowns.first?.endpointID, endpointA)

        let reloadedEndpointReport = try await TokenUsageStore(fileURL: fileURL).report(
            from: now.addingTimeInterval(-60 * 60),
            to: now,
            bucketInterval: 5 * 60,
            endpointID: endpointB
        )
        XCTAssertEqual(reloadedEndpointReport.totalTokens, 50)
        XCTAssertEqual(reloadedEndpointReport.requestCount, 1)
    }
}

private actor TunnelStatusRecorder {
    private var values: [TunnelStatus] = []

    var phases: [TunnelPhase] {
        values.map(\.phase)
    }

    var statuses: [TunnelStatus] { values }

    func append(_ status: TunnelStatus) {
        values.append(status)
    }
}

private final class FakeEndpointSecretStore: EndpointSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String]

    init(values: [UUID: String] = [:]) { self.values = values }

    func token(for endpointID: UUID) throws -> String? {
        lock.withLock { values[endpointID] }
    }

    func setToken(_ token: String?, for endpointID: UUID) throws {
        lock.withLock { values[endpointID] = token }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

private func waitForPhase(
    _ phase: TunnelPhase,
    in recorder: TunnelStatusRecorder,
    attempts: Int = 40
) async -> Bool {
    for _ in 0..<attempts {
        if await recorder.phases.contains(phase) { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

private func waitForPhase(
    _ phase: TunnelPhase,
    tunnelID: UUID,
    minimumCount: Int = 1,
    in recorder: TunnelStatusRecorder,
    attempts: Int = 80
) async -> Bool {
    for _ in 0..<attempts {
        let count = await recorder.statuses.filter {
            $0.tunnelID == tunnelID && $0.phase == phase
        }.count
        if count >= minimumCount { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

private func writeFakeSSH(
    executableURL: URL,
    eventsURL: URL,
    exitMasterAfter lifetime: Double? = nil
) throws {
    let masterBody: String
    if let lifetime {
        masterBody = "sleep \(lifetime); rm -f \"$ready\""
    } else {
        masterBody = "while [ -f \"$ready\" ]; do sleep 0.05; done"
    }
    let script = """
    #!/bin/sh
    control=""
    operation=""
    master=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -M) master=1; shift ;;
        -S) control="$2"; shift 2 ;;
        -O) operation="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    ready="${control}.ready"
    case "$operation" in
      check) [ -f "$ready" ]; exit $? ;;
      forward) echo "forward:$control" >> "\(eventsURL.path)"; exit 0 ;;
      cancel) echo "cancel:$control" >> "\(eventsURL.path)"; exit 0 ;;
      exit)
        if [ -f "$ready" ]; then
          echo "exit:$control" >> "\(eventsURL.path)"
          rm -f "$ready"
        fi
        exit 0
        ;;
    esac
    if [ "$master" -eq 1 ]; then
      touch "$ready"
      echo "master:$control" >> "\(eventsURL.path)"
      \(masterBody)
      exit 0
    fi
    exit 0
    """
    try Data(script.utf8).write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
}
