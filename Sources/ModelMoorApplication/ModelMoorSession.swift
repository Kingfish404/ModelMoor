import Foundation
import ModelMoorCore
import ModelMoorGateway
import ModelMoorSystem

public enum SessionError: LocalizedError, Equatable {
    case runtimeOwnedElsewhere(owner: String?)
    case runtimeNotOwned
    case tunnelNotFound(UUID)
    case endpointNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case let .runtimeOwnedElsewhere(owner):
            if let owner, !owner.isEmpty {
                return "The runtime is already owned by \(owner). Quit that process or use its controls."
            }
            return "The runtime is already owned by another ModelMoor process."
        case .runtimeNotOwned:
            return "The runtime is not started. Call startRuntime (or connect through the owning process) first."
        case let .tunnelNotFound(id):
            return "Mooring not found: \(id.uuidString)"
        case let .endpointNotFound(id):
            return "Endpoint not found: \(id.uuidString)"
        }
    }
}

public typealias CLIProxyServiceFactory = @Sendable (
    URL,
    @escaping @Sendable (CLIProxyRuntimeState) -> Void
) -> any CLIProxyServicing

public typealias CLIProxyManagementFactory = @Sendable (
    Int,
    String
) -> any CLIProxyManaging

/// The single business entry point shared by the macOS GUI, the `modelmoor`
/// CLI and `modelmoor-tui` (docs/PLAN.md §4). Owns configuration
/// transactions, deletion cascades, tunnel/Gateway lifecycle, endpoint
/// inspection, usage reads and the bounded diagnostic log. Presentation
/// layers render `AppSnapshot` and issue typed commands; they never touch
/// stores or services directly.
public actor ModelMoorSession {
    private static let endpointInspectionConcurrency = 4

    public internal(set) var snapshot: AppSnapshot

    private let profile: ModelMoorRuntimeProfile
    private let store: ConfigurationStore
    private let interactiveSecretStore: any ModelMoorSecretStore
    private let nonInteractiveSecretStore: any ModelMoorSecretStore
    private let deletionCoordinator: ConfigurationDeletionCoordinator
    private let usageStore: TokenUsageStore
    private let inspector: any APIInspecting
    private let sshConfigScanner: any SSHConfigScanning
    private let diagnostics: DiagnosticLog
    private let runtimeLockURL: URL

    private var tunnelService: TunnelService?
    private var gatewayCoordinator: GatewayServiceCoordinator?
    private var ownership: RuntimeOwnership?
    private var networkMonitor: NetworkMonitor?
    private var networkAvailable = true
    private var runtimeSuspended = false
    private var subscribers: [UUID: AsyncStream<AppSnapshot>.Continuation] = [:]
    private var inspectionGenerations: [UUID: UInt64] = [:]
    private var inspectionBatch: (id: UUID, task: Task<Void, Never>)?
    private var sshTargetScan: (id: UUID, task: Task<[SSHHostTarget], Error>)?
    private var credentialAvailabilityRefresh: (
        id: UUID,
        keyIDs: Set<UUID>,
        task: Task<Set<UUID>, Never>
    )?
    let cliProxyServiceFactory: CLIProxyServiceFactory
    let cliProxyManagementFactory: CLIProxyManagementFactory
    let subscriptionUsageProvider: any SubscriptionUsageProviding
    var managedSubscriptionCoordinator: ManagedSubscriptionCoordinator?
    var managedSubscriptionCoordinatorID: UUID?
    var managedSubscriptionSnapshotRevision: UInt64 = 0

    public init(
        profile: ModelMoorRuntimeProfile = .current,
        store: ConfigurationStore? = nil,
        secretStore: (any ModelMoorSecretStore)? = nil,
        usageStore: TokenUsageStore? = nil,
        inspector: any APIInspecting = APIInspector(),
        sshConfigScanner: any SSHConfigScanning = SSHConfigScanner(),
        diagnostics: DiagnosticLog = DiagnosticLog(),
        runtimeLockURL: URL? = nil,
        gatewayCoordinator: GatewayServiceCoordinator? = nil,
        cliProxyServiceFactory: @escaping CLIProxyServiceFactory = { dataDirectoryURL, handler in
            CLIProxyService(dataDirectoryURL: dataDirectoryURL, stateHandler: handler)
        },
        cliProxyManagementFactory: @escaping CLIProxyManagementFactory = { port, password in
            CLIProxyManagementClient(port: port, managementPassword: password)
        },
        subscriptionUsageProvider: (any SubscriptionUsageProviding)? = nil
    ) throws {
        let resolvedSecretStore: any ModelMoorSecretStore
        if let secretStore {
            resolvedSecretStore = secretStore
        } else {
            do {
                resolvedSecretStore = try SecretStoreResolver.defaultStore(profile: profile)
            } catch {
                // Read-only surfaces must work before a secret backend is
                // enabled; writes fail loudly through the fallback store.
                resolvedSecretStore = UnavailableSecretStore(reason: error.localizedDescription)
            }
        }
        let resolvedStore = store ?? ConfigurationStore(
            fileURL: profile.configurationURL,
            legacyImportURL: profile.legacyConfigurationURL,
            initialConfiguration: profile.initialConfiguration,
            endpointCredentialLookup: { try resolvedSecretStore.token(for: $0) }
        )
        let resolvedSubscriptionUsageProvider = subscriptionUsageProvider ?? CodexBarUsageService(
            authDirectoryURL: profile.cliProxyDataDirectoryURL
                .appendingPathComponent("auths", isDirectory: true)
        )
        self.profile = profile
        self.store = resolvedStore
        self.interactiveSecretStore = resolvedSecretStore
        self.nonInteractiveSecretStore = resolvedSecretStore.disallowingUserInteraction()
        self.deletionCoordinator = ConfigurationDeletionCoordinator(
            store: resolvedStore,
            secretStore: resolvedSecretStore
        )
        self.usageStore = usageStore ?? TokenUsageStore(fileURL: profile.tokenUsageURL)
        self.inspector = inspector
        self.sshConfigScanner = sshConfigScanner
        self.diagnostics = diagnostics
        self.runtimeLockURL = runtimeLockURL ?? profile.runtimeLockURL
        self.gatewayCoordinator = gatewayCoordinator
        self.cliProxyServiceFactory = cliProxyServiceFactory
        self.cliProxyManagementFactory = cliProxyManagementFactory
        self.subscriptionUsageProvider = resolvedSubscriptionUsageProvider
        self.snapshot = AppSnapshot(
            subscriptions: ManagedSubscriptionSnapshot(
                isUsageProviderAvailable: resolvedSubscriptionUsageProvider.isAvailable
            )
        )
    }

    // MARK: - Snapshots

    /// Current snapshot plus the latest future state. Intermediate states may
    /// coalesce when a subscriber is slower than the runtime, preventing an
    /// inactive GUI or TUI from accumulating an unbounded render backlog.
    /// Cancelling the stream's task detaches the subscriber.
    public nonisolated func snapshots() -> AsyncStream<AppSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            Task { await self.attach(subscriber: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.detach(subscriber: id) }
            }
        }
    }

    private func attach(
        subscriber id: UUID,
        continuation: AsyncStream<AppSnapshot>.Continuation
    ) {
        subscribers[id] = continuation
        continuation.yield(snapshot)
    }

    private func detach(subscriber id: UUID) {
        subscribers[id] = nil
    }

    func emit() {
        let current = snapshot
        for continuation in subscribers.values {
            continuation.yield(current)
        }
    }

    // MARK: - Configuration commands

    /// Loads configuration from disk and resets requested tunnels to the
    /// configuration's connectOnLaunch set.
    public func load() async throws {
        let configuration = try await store.load()
        snapshot.configuration = configuration
        snapshot.requestedTunnelIDs = Set(configuration.tunnels.filter(\.connectOnLaunch).map(\.id))
        snapshot.availableEndpointAPIKeyIDs = await resolveEndpointCredentialAvailability(
            for: endpointAPIKeyIDs(in: configuration)
        )
        snapshot.isLoaded = true
        await refreshUsage()
        emit()
    }

    /// Validates, persists and re-applies a configuration replacement.
    /// Runtime-facing state (requested tunnels, connections) is preserved for
    /// tunnels that still exist.
    public func saveConfiguration(_ configuration: ModelMoorConfiguration) async throws {
        let validated = try configuration.validated()
        let previousCredentialIDs = endpointAPIKeyIDs(in: snapshot.configuration)
        try await store.save(validated)
        snapshot.configuration = validated
        snapshot.requestedTunnelIDs.formIntersection(validated.tunnels.map(\.id))
        let currentCredentialIDs = endpointAPIKeyIDs(in: validated)
        snapshot.availableEndpointAPIKeyIDs.formIntersection(currentCredentialIDs)
        emit()
        if currentCredentialIDs != previousCredentialIDs {
            await refreshEndpointCredentialAvailability()
        }
        await reconcileTunnels()
        await reconcileManagedSubscriptions()
        await reconcileGateway()
    }

    /// Ensures that the first enabled Unified API key exists in the platform
    /// secret store. Presentations use this after editing gateway settings so
    /// the TUI can configure the API without ever handling or persisting a
    /// plaintext key itself.
    public func ensureGatewayAPIKey() async throws {
        guard let key = snapshot.configuration.gateway.apiKeys.first(where: \.enabled) else {
            throw ConfigurationError.invalidValue("Unified API requires an enabled API key.")
        }
        _ = try interactiveSecretStore.ensureGatewayAPIKey(for: key.id)
        if ownership != nil {
            await reconcileGateway()
        }
    }

    public func removeTunnel(_ tunnelID: UUID) async throws -> ConfigurationCascadeResult {
        await tunnelService?.stop(tunnelID)
        let result = try await deletionCoordinator.removeTunnel(
            tunnelID,
            from: snapshot.configuration
        )
        snapshot.configuration = result.configuration
        snapshot.tunnelStatuses[tunnelID] = nil
        snapshot.requestedTunnelIDs.remove(tunnelID)
        emit()
        await reconcileGateway()
        return result
    }

    public func removeMapping(
        _ mappingID: UUID,
        fromTunnel tunnelID: UUID
    ) async throws -> ConfigurationCascadeResult {
        let result = try await deletionCoordinator.removeMapping(
            mappingID,
            fromTunnel: tunnelID,
            in: snapshot.configuration
        )
        snapshot.configuration = result.configuration
        emit()
        if let tunnel = result.configuration.tunnels.first(where: { $0.id == tunnelID }),
           snapshot.requestedTunnelIDs.contains(tunnelID) {
            await tunnelService?.start(tunnel)
        }
        await reconcileGateway()
        return result
    }

    public func removeEndpoint(_ endpointID: UUID) async throws -> ConfigurationCascadeResult {
        let result = try await deletionCoordinator.removeEndpoint(
            endpointID,
            from: snapshot.configuration
        )
        snapshot.configuration = result.configuration
        snapshot.inspections[endpointID] = nil
        snapshot.availableEndpointAPIKeyIDs.formIntersection(
            endpointAPIKeyIDs(in: result.configuration)
        )
        emit()
        await reconcileGateway()
        return result
    }

    public func addEndpoint(
        _ endpoint: APIEndpointConfiguration,
        secret: String?
    ) async throws {
        let updated = try await deletionCoordinator.addEndpoint(
            endpoint,
            secret: secret,
            to: snapshot.configuration
        )
        snapshot.configuration = updated
        emit()
        await reconcileGateway()
    }

    // MARK: - Runtime commands

    /// Acquires the shared runtime owner lock and starts the requested
    /// tunnels plus the Unified API listener. GUI, `modelmoor run` and
    /// `modelmoor-tui` can never own the runtime at the same time; the loser
    /// receives `RuntimeOwnershipError.alreadyOwned`.
    ///
    /// - Parameter tunnelIDs: `nil` starts the configuration's
    ///   `connectOnLaunch` tunnels; an explicit set overrides (used by
    ///   `modelmoor run NAME`).
    public func startRuntime(
        owner: String,
        tunnelIDs: Set<UUID>? = nil
    ) async throws {
        if ownership == nil {
            ownership = try RuntimeOwnership.acquire(
                lockFileURL: runtimeLockURL,
                owner: owner
            )
        }
        if let tunnelIDs {
            snapshot.requestedTunnelIDs = tunnelIDs.intersection(snapshot.configuration.tunnels.map(\.id))
        } else {
            snapshot.requestedTunnelIDs = Set(
                snapshot.configuration.tunnels.filter(\.connectOnLaunch).map(\.id)
            )
        }
        snapshot.runtimeState = .running
        ensureTunnelService()
        startNetworkMonitoring()
        emit()
        await reconcileTunnels()
        await reconcileManagedSubscriptions()
        await reconcileGateway()
    }

    public func stopRuntime() async {
        networkMonitor?.cancel()
        networkMonitor = nil
        await managedSubscriptionCoordinator?.shutdown()
        managedSubscriptionCoordinator = nil
        managedSubscriptionCoordinatorID = nil
        managedSubscriptionSnapshotRevision = 0
        snapshot.subscriptions = ManagedSubscriptionSnapshot(
            isUsageProviderAvailable: subscriptionUsageProvider.isAvailable
        )
        if let gatewayCoordinator {
            _ = await gatewayCoordinator.reconcile(snapshot: nil)
        }
        gatewayCoordinator = nil
        await tunnelService?.stopAll()
        tunnelService = nil
        ownership = nil
        snapshot.gatewayState = .stopped
        for id in snapshot.tunnelStatuses.keys {
            snapshot.tunnelStatuses[id] = TunnelStatus(tunnelID: id, phase: .stopped, message: "Stopped")
        }
        snapshot.runtimeState = .stopped
        emit()
    }

    /// Re-evaluates the Unified API listener against the current snapshot.
    /// Safe to call after credential or managed-sidecar (CLIProxy) changes.
    public func refreshGateway() async {
        await reconcileGateway()
    }

    /// Advisory, lock-free view of the current runtime owner for read-only
    /// surfaces. Nil when no runtime lock file exists.
    public nonisolated func recordedRuntimeOwner() -> String? {
        RuntimeOwnership.recordedOwner(lockFileURL: runtimeLockURL)
    }

    /// Re-evaluates who owns the runtime without attempting to acquire it.
    /// Read-only surfaces call this on refresh so they can show the owning
    /// process instead of silently taking over the runtime.
    public func refreshRuntimeState() {
        guard ownership == nil else {
            if snapshot.runtimeState != .running {
                snapshot.runtimeState = .running
                emit()
            }
            return
        }
        let recorded = recordedRuntimeOwner()
        let replacement: SessionRuntimeState = recorded == nil
            ? .stopped
            : .ownedExternally(owner: recorded)
        if snapshot.runtimeState != replacement {
            snapshot.runtimeState = replacement
            emit()
        }
    }

    public func connectTunnel(_ tunnelID: UUID) async throws {
        guard ownership != nil else {
            throw SessionError.runtimeOwnedElsewhere(owner: recordedRuntimeOwner())
        }
        guard let tunnel = snapshot.configuration.tunnels.first(where: { $0.id == tunnelID }) else {
            throw SessionError.tunnelNotFound(tunnelID)
        }
        snapshot.requestedTunnelIDs.insert(tunnelID)
        emit()
        guard networkAvailable else {
            await tunnelService?.setRuntimeAvailable(false, reason: "Waiting for network")
            return
        }
        await tunnelService?.start(tunnel)
    }

    public func disconnectTunnel(_ tunnelID: UUID) async {
        snapshot.requestedTunnelIDs.remove(tunnelID)
        emit()
        await tunnelService?.stop(tunnelID)
    }

    /// Starts every tunnel that has at least one enabled mapping. Used by the
    /// GUI "Connect All" action; requires this process to own the runtime.
    public func connectAllTunnels() async throws {
        guard ownership != nil else {
            throw SessionError.runtimeOwnedElsewhere(owner: recordedRuntimeOwner())
        }
        snapshot.requestedTunnelIDs = Set(
            snapshot.configuration.tunnels.filter { !$0.enabledMappings.isEmpty }.map(\.id)
        )
        emit()
        await reconcileTunnels()
    }

    public func disconnectAllTunnels() async {
        snapshot.requestedTunnelIDs.removeAll()
        emit()
        await tunnelService?.stopAll()
    }

    /// Sleep/wake support: suspends tunnel retries and stops the listener
    /// without releasing the runtime owner lock, then resumes on wake.
    /// Only meaningful while this process owns the runtime.
    public func suspendRuntime(reason: String) async {
        guard ownership != nil else { return }
        runtimeSuspended = true
        await managedSubscriptionCoordinator?.setSuspended(true)
        if let gatewayCoordinator {
            snapshot.gatewayState = await gatewayCoordinator.reconcile(snapshot: nil)
        }
        await tunnelService?.setRuntimeAvailable(false, reason: reason)
        await diagnostics.append(
            subject: .gateway,
            severity: .info,
            category: "sleep",
            summary: "Runtime suspended: \(reason)"
        )
        emit()
    }

    public func resumeRuntime() async {
        guard ownership != nil else { return }
        runtimeSuspended = false
        await reconcileManagedSubscriptions()
        await tunnelService?.setRuntimeAvailable(networkAvailable, reason: "Waiting for network")
        if networkAvailable {
            await inspectAllEndpoints()
            await reconcileGateway()
        }
    }

    // MARK: - Inspection, usage, diagnostics

    /// Inspects an unsaved endpoint draft without publishing its result or
    /// secret to the shared snapshot. This keeps onboarding validation in the
    /// business layer while the sheet remains responsible for draft fields.
    public func inspectTemporaryEndpoint(
        _ endpoint: APIEndpointConfiguration,
        secret: String?
    ) async -> EndpointInspection {
        let cleanSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        return await inspector.inspect(
            endpoint,
            mappings: [:],
            secret: cleanSecret?.isEmpty == false ? cleanSecret : nil
        )
    }

    public func inspectEndpoint(_ endpointID: UUID) async {
        guard let endpoint = snapshot.configuration.endpoints.first(where: { $0.id == endpointID }) else {
            return
        }
        let mappings = Dictionary(
            uniqueKeysWithValues: snapshot.configuration.tunnels.flatMap(\.mappings).map { ($0.id, $0) }
        )
        var secret: String?
        if let keyID = endpoint.activeAPIKeyID {
            secret = try? nonInteractiveSecretStore.token(for: keyID)
        }
        let generation = nextInspectionGeneration(for: endpointID)
        let inspection = await inspector.inspect(endpoint, mappings: mappings, secret: secret)
        guard inspectionGenerations[endpointID] == generation,
              snapshot.configuration.endpoints.contains(endpoint) else {
            return
        }
        snapshot.inspections[endpointID] = inspection
        await recordInspection(inspection, endpoint: endpoint)
        emit()
    }

    /// Inspects every enabled endpoint whose transport can work, with bounded
    /// parallelism. Concurrent refresh requests share the same batch so menu,
    /// window and lifecycle refreshes cannot multiply network traffic. Results
    /// are committed in one snapshot to avoid a full UI redraw per endpoint.
    public func inspectAllEndpoints() async {
        if let inspectionBatch {
            await inspectionBatch.task.value
            return
        }
        let batchID = UUID()
        let task = Task { await self.performEndpointInspectionBatch() }
        inspectionBatch = (batchID, task)
        await task.value
        if inspectionBatch?.id == batchID {
            inspectionBatch = nil
        }
    }

    private func performEndpointInspectionBatch() async {
        let connectedTunnelIDs = Set(snapshot.tunnelStatuses.values.compactMap { status in
            status.phase == .connected ? status.tunnelID : nil
        })
        let connectedMappingIDs = Set(snapshot.configuration.tunnels.lazy
            .filter { connectedTunnelIDs.contains($0.id) }
            .flatMap(\.mappings)
            .map(\.id))
        let mappings = Dictionary(
            uniqueKeysWithValues: snapshot.configuration.tunnels
                .flatMap(\.mappings).map { ($0.id, $0) }
        )
        let candidates = snapshot.configuration.endpoints.compactMap { endpoint -> InspectionRequest? in
            guard endpoint.enabled else { return nil }
            if case let .sshMapping(mappingID, _) = endpoint.source,
               !connectedMappingIDs.contains(mappingID) {
                return nil
            }
            let secret = endpoint.activeAPIKeyID.flatMap {
                try? nonInteractiveSecretStore.token(for: $0)
            }
            return InspectionRequest(
                endpoint: endpoint,
                mappings: mappings,
                secret: secret,
                generation: nextInspectionGeneration(for: endpoint.id)
            )
        }
        guard !candidates.isEmpty else { return }

        let inspector = self.inspector
        let results = await Self.inspect(
            candidates,
            using: inspector,
            concurrency: Self.endpointInspectionConcurrency
        )
        var accepted: [(EndpointInspection, APIEndpointConfiguration)] = []
        for result in results {
            guard inspectionGenerations[result.endpoint.id] == result.generation,
                  snapshot.configuration.endpoints.contains(result.endpoint) else {
                continue
            }
            snapshot.inspections[result.endpoint.id] = result.inspection
            accepted.append((result.inspection, result.endpoint))
        }
        for (inspection, endpoint) in accepted {
            await recordInspection(inspection, endpoint: endpoint)
        }
        if !accepted.isEmpty {
            emit()
        }
    }

    private func nextInspectionGeneration(for endpointID: UUID) -> UInt64 {
        let next = (inspectionGenerations[endpointID] ?? 0) &+ 1
        inspectionGenerations[endpointID] = next
        return next
    }

    private nonisolated static func inspect(
        _ requests: [InspectionRequest],
        using inspector: any APIInspecting,
        concurrency: Int
    ) async -> [InspectionResult] {
        await withTaskGroup(of: InspectionResult.self, returning: [InspectionResult].self) { group in
            var iterator = requests.makeIterator()
            for _ in 0..<min(concurrency, requests.count) {
                guard let request = iterator.next() else { break }
                group.addTask { await inspect(request, using: inspector) }
            }

            var results: [InspectionResult] = []
            results.reserveCapacity(requests.count)
            while let result = await group.next() {
                results.append(result)
                if let request = iterator.next() {
                    group.addTask { await inspect(request, using: inspector) }
                }
            }
            return results
        }
    }

    private nonisolated static func inspect(
        _ request: InspectionRequest,
        using inspector: any APIInspecting
    ) async -> InspectionResult {
        let inspection = await inspector.inspect(
            request.endpoint,
            mappings: request.mappings,
            secret: request.secret
        )
        return InspectionResult(
            endpoint: request.endpoint,
            inspection: inspection,
            generation: request.generation
        )
    }

    private struct InspectionRequest: Sendable {
        let endpoint: APIEndpointConfiguration
        let mappings: [UUID: PortMappingConfiguration]
        let secret: String?
        let generation: UInt64
    }

    private struct InspectionResult: Sendable {
        let endpoint: APIEndpointConfiguration
        let inspection: EndpointInspection
        let generation: UInt64
    }

    public func refreshUsage() async {
        do {
            let usage = try await usageStore.snapshot()
            if usage != snapshot.usage {
                snapshot.usage = usage
                emit()
            }
        } catch {
            await diagnostics.append(
                subject: .gateway,
                severity: .warning,
                category: "usage.read",
                summary: error.localizedDescription
            )
        }
    }

    /// Parameterized historical usage stays out of `AppSnapshot`: callers
    /// request only the currently visible range and cancellation is preserved.
    public func tokenUsageReport(
        from startDate: Date,
        to endDate: Date,
        bucketInterval: TimeInterval,
        routeID: UUID? = nil,
        endpointID: UUID? = nil
    ) async throws -> TokenUsageReport {
        do {
            return try await usageStore.report(
                from: startDate,
                to: endDate,
                bucketInterval: bucketInterval,
                routeID: routeID,
                endpointID: endpointID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await diagnostics.append(
                subject: .gateway,
                severity: .warning,
                category: "usage.report",
                summary: error.localizedDescription
            )
            throw error
        }
    }

    /// Coalesces simultaneous filesystem scans from sheets, settings and
    /// refresh commands. The blocking config parser runs on a utility task,
    /// never on the presentation actor.
    @discardableResult
    public func refreshSSHTargets() async throws -> [SSHHostTarget] {
        if let sshTargetScan {
            return try await sshTargetScan.task.value
        }

        let scanID = UUID()
        let scanner = sshConfigScanner
        let task = Task.detached(priority: .utility) {
            try scanner.discoverTargets()
        }
        sshTargetScan = (scanID, task)
        snapshot.isRefreshingSSHTargets = true
        emit()

        do {
            let targets = try await task.value
            if sshTargetScan?.id == scanID {
                sshTargetScan = nil
                snapshot.sshTargets = targets
                snapshot.isRefreshingSSHTargets = false
                emit()
            }
            return targets
        } catch {
            if sshTargetScan?.id == scanID {
                sshTargetScan = nil
                snapshot.isRefreshingSSHTargets = false
                emit()
            }
            await diagnostics.append(
                subject: .system,
                severity: .warning,
                category: "ssh.config.read",
                summary: error.localizedDescription
            )
            throw error
        }
    }

    /// Refreshes secret presence as an ID-only projection. Non-interactive
    /// storage prevents authentication prompts during background rendering.
    public func refreshEndpointCredentialAvailability() async {
        let keyIDs = endpointAPIKeyIDs(in: snapshot.configuration)
        let available = await resolveEndpointCredentialAvailability(for: keyIDs)
        guard keyIDs == endpointAPIKeyIDs(in: snapshot.configuration) else { return }
        if snapshot.availableEndpointAPIKeyIDs != available {
            snapshot.availableEndpointAPIKeyIDs = available
            emit()
        }
    }

    private func resolveEndpointCredentialAvailability(
        for keyIDs: Set<UUID>
    ) async -> Set<UUID> {
        if let refresh = credentialAvailabilityRefresh,
           refresh.keyIDs == keyIDs {
            return await refresh.task.value
        }

        credentialAvailabilityRefresh?.task.cancel()
        let refreshID = UUID()
        let secretStore = nonInteractiveSecretStore
        let task = Task.detached(priority: .utility) {
            var available: Set<UUID> = []
            available.reserveCapacity(keyIDs.count)
            for keyID in keyIDs where !Task.isCancelled {
                if (try? secretStore.token(for: keyID))?.isEmpty == false {
                    available.insert(keyID)
                }
            }
            return available
        }
        credentialAvailabilityRefresh = (refreshID, keyIDs, task)
        let result = await task.value
        if credentialAvailabilityRefresh?.id == refreshID {
            credentialAvailabilityRefresh = nil
        }
        return result
    }

    private func endpointAPIKeyIDs(
        in configuration: ModelMoorConfiguration
    ) -> Set<UUID> {
        Set(configuration.endpoints.flatMap { endpoint in
            endpoint.apiKeys.map(\.id)
        })
    }

    func setEndpointCredentialAvailable(_ available: Bool, keyID: UUID) {
        credentialAvailabilityRefresh?.task.cancel()
        credentialAvailabilityRefresh = nil
        if available {
            snapshot.availableEndpointAPIKeyIDs.insert(keyID)
        } else {
            snapshot.availableEndpointAPIKeyIDs.remove(keyID)
        }
        emit()
    }

    /// Mirrors the historical GUI behavior: inspection outcomes land in the
    /// bounded, redacted diagnostic log so Copy Diagnostic Summary and the
    /// TUI "Needs Attention" pane can show them.
    private func recordInspection(
        _ inspection: EndpointInspection,
        endpoint: APIEndpointConfiguration
    ) async {
        let isLLMAPI = endpoint.kind.isLLMAPI
            && snapshot.inspections[endpoint.id]?.classification != .otherHTTPService
        let severity: DiagnosticSeverity = inspection.errorMessage == nil || !isLLMAPI ? .info : .warning
        let category = inspection.statusCode.map { "http.\($0)" } ?? "inspection"
        let summary = inspection.errorMessage
            ?? inspection.models.map { "Endpoint ready; \($0.count) model(s) discovered" }
            ?? "Endpoint reachable"
        await diagnostics.append(
            subject: .endpoint(endpoint.id),
            severity: severity,
            category: category,
            summary: summary
        )
    }

    /// Bounded, redacted diagnostic summary: no tokens, no full home paths,
    /// no SSH private arguments, no inference bodies.
    public func diagnosticSummary() async -> String {
        await diagnostics.summary()
    }

    public func logDiagnostic(
        subject: DiagnosticSubject,
        severity: DiagnosticSeverity,
        category: String,
        summary: String,
        secrets: [String] = []
    ) async {
        await diagnostics.append(
            subject: subject,
            severity: severity,
            category: category,
            summary: summary,
            secrets: secrets
        )
    }

    // MARK: - Internal accessors for same-module extensions

    func secretStore() -> any ModelMoorSecretStore { interactiveSecretStore }
    func backgroundSecretStore() -> any ModelMoorSecretStore { nonInteractiveSecretStore }
    func ownsRuntime() -> Bool { ownership != nil }
    func isRuntimeSuspended() -> Bool { runtimeSuspended }
    func cliProxyDataDirectoryURL() -> URL { profile.cliProxyDataDirectoryURL }
    func diagnosticLog() -> DiagnosticLog { diagnostics }

    /// Reconciles the listener after secret-only changes (key rotation etc.)
    /// that did not alter the configuration file.
    func reconcileGatewayAfterCredentialChange() async {
        await reconcileGateway()
    }

    // MARK: - Internals

    private func ensureTunnelService() {
        guard tunnelService == nil else { return }
        tunnelService = TunnelService(
            commandBuilder: SSHCommandBuilder(controlDirectoryURL: profile.runtimeDirectoryURL)
        ) { [weak self] status in
            Task { await self?.handleTunnelStatus(status) }
        }
    }

    private func handleTunnelStatus(_ status: TunnelStatus) async {
        snapshot.tunnelStatuses[status.tunnelID] = status
        await diagnostics.append(
            subject: .mooring(status.tunnelID),
            severity: status.phase == .failed ? .error : (status.failureCategory == nil ? .info : .warning),
            category: status.failureCategory?.rawValue ?? status.phase.rawValue,
            summary: status.message
        )
        emit()
        if status.phase == .connected {
            await inspectAllEndpoints()
        }
        await reconcileGateway()
    }

    private func reconcileTunnels() async {
        guard ownership != nil else { return }
        let desired = snapshot.configuration.tunnels.filter {
            snapshot.requestedTunnelIDs.contains($0.id)
        }
        await tunnelService?.reconcile(desired)
    }

    private func reconcileGateway() async {
        guard ownership != nil, !runtimeSuspended else { return }
        let configuration = snapshot.configuration
        guard configuration.gateway.enabled else {
            if let gatewayCoordinator {
                snapshot.gatewayState = await gatewayCoordinator.reconcile(snapshot: nil)
                emit()
            }
            return
        }
        do {
            let gatewayAPIKeys = try nonInteractiveSecretStore.enabledGatewayAPIKeys(for: configuration.gateway)
            let secrets = nonInteractiveSecretStore.endpointSecrets(for: configuration)
            let connectedMappings = Set(configuration.tunnels.compactMap { tunnel -> [UUID]? in
                snapshot.tunnelStatuses[tunnel.id]?.phase == .connected ? tunnel.enabledMappings.map(\.id) : nil
            }.flatMap { $0 })
            let gatewaySnapshot = GatewaySnapshot(
                configuration: configuration,
                gatewayAPIKeys: gatewayAPIKeys,
                endpointSecrets: secrets,
                availableMappingIDs: connectedMappings
            )
            snapshot.gatewayState = await gatewayRuntime().reconcile(snapshot: gatewaySnapshot)
            switch snapshot.gatewayState {
            case .running:
                await diagnostics.append(
                    subject: .gateway,
                    severity: .info,
                    category: "ready",
                    summary: "Gateway listening on loopback port \(configuration.gateway.listenPort)"
                )
            case let .failed(message):
                await diagnostics.append(
                    subject: .gateway,
                    severity: .error,
                    category: "failed",
                    summary: message
                )
            case .stopped:
                break
            }
        } catch {
            snapshot.gatewayState = .failed(error.localizedDescription)
            await diagnostics.append(
                subject: .gateway,
                severity: .error,
                category: "failed",
                summary: error.localizedDescription
            )
        }
        emit()
    }

    private func gatewayRuntime() -> GatewayServiceCoordinator {
        if let gatewayCoordinator { return gatewayCoordinator }
        let usageStore = self.usageStore
        let diagnostics = self.diagnostics
        let coordinator = GatewayServiceCoordinator { usage in
            Task {
                do {
                    try await usageStore.appendUsage(
                        tokens: usage.tokens,
                        routeID: usage.routeID,
                        endpointID: usage.endpointID
                    )
                } catch {
                    await diagnostics.append(
                        subject: .gateway,
                        severity: .warning,
                        category: "usage.write",
                        summary: error.localizedDescription
                    )
                }
            }
        }
        gatewayCoordinator = coordinator
        return coordinator
    }

    private func startNetworkMonitoring() {
        guard networkMonitor == nil else { return }
        let monitor = NetworkMonitor { [weak self] availability in
            Task { await self?.networkAvailabilityChanged(availability) }
        }
        networkMonitor = monitor
        monitor.start()
    }

    private func networkAvailabilityChanged(_ availability: NetworkAvailability) async {
        networkAvailable = availability == .available
        await tunnelService?.setRuntimeAvailable(networkAvailable, reason: "Waiting for network")
        if networkAvailable {
            await inspectAllEndpoints()
            await reconcileGateway()
        }
    }
}
