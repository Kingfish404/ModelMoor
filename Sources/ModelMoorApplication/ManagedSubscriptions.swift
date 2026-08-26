import Foundation
import ModelMoorCore
import ModelMoorSystem

public enum ManagedSubscriptionError: LocalizedError, Equatable {
    case proxyUnavailable
    case managementCredentialUnavailable
    case loginFailed(String)
    case loginTimedOut

    public var errorDescription: String? {
        switch self {
        case .proxyUnavailable:
            "The managed subscription proxy is not running."
        case .managementCredentialUnavailable:
            "The subscription proxy management credential is unavailable in the secret store."
        case let .loginFailed(message):
            message
        case .loginTimedOut:
            "Account sign-in timed out. Start the sign-in again."
        }
    }
}

public struct ManagedSubscriptionActionAvailability: Equatable, Sendable {
    public let canStartLogin: Bool
    public let canRefreshAccounts: Bool
    public let canMutateAccounts: Bool

    public init(
        canStartLogin: Bool,
        canRefreshAccounts: Bool,
        canMutateAccounts: Bool
    ) {
        self.canStartLogin = canStartLogin
        self.canRefreshAccounts = canRefreshAccounts
        self.canMutateAccounts = canMutateAccounts
    }
}

public enum ManagedSubscriptionInteractionPolicy {
    /// Command state shared by every presentation. Starting a first login may
    /// enable and launch the helper, while account refresh/mutation requires
    /// the helper to be confirmed running in the owning process.
    public static func availability(
        runtimeState: SessionRuntimeState,
        cliProxyState: CLIProxyRuntimeState,
        hasActiveLogin: Bool
    ) -> ManagedSubscriptionActionAvailability {
        let ownsRuntime: Bool
        if case .running = runtimeState {
            ownsRuntime = true
        } else {
            ownsRuntime = false
        }
        let helperIsRunning: Bool
        if case .running = cliProxyState {
            helperIsRunning = true
        } else {
            helperIsRunning = false
        }
        return ManagedSubscriptionActionAvailability(
            canStartLogin: ownsRuntime && !hasActiveLogin,
            canRefreshAccounts: ownsRuntime && helperIsRunning,
            canMutateAccounts: ownsRuntime && helperIsRunning
        )
    }
}

struct ManagedSubscriptionUpdate: Sendable {
    let coordinatorID: UUID
    let revision: UInt64
    let snapshot: ManagedSubscriptionSnapshot
}

/// Owns the managed helper process, its management API, login polling,
/// bounded restart policy and optional subscription-usage reader. The actor
/// deliberately has no AppKit/SwiftUI dependency; ModelMoorSession publishes
/// its secret-free snapshot to GUI, CLI and TUI consumers.
actor ManagedSubscriptionCoordinator {
    nonisolated let id = UUID()
    private(set) var snapshot: ManagedSubscriptionSnapshot

    private let dataDirectoryURL: URL
    private let secretStore: any ModelMoorSecretStore
    private let diagnostics: DiagnosticLog
    private let serviceFactory: CLIProxyServiceFactory
    private let managementFactory: CLIProxyManagementFactory
    private let usageProvider: any SubscriptionUsageProviding
    private let snapshotHandler: @Sendable (ManagedSubscriptionUpdate) async -> Void

    private var configuration: CLIProxyConfiguration?
    private var service: (any CLIProxyServicing)?
    private var loginTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var stabilityTask: Task<Void, Never>?
    private var restartAttempt = 0
    private var suspended = false
    private var snapshotRevision: UInt64 = 0

    init(
        dataDirectoryURL: URL,
        secretStore: any ModelMoorSecretStore,
        diagnostics: DiagnosticLog,
        serviceFactory: @escaping CLIProxyServiceFactory,
        managementFactory: @escaping CLIProxyManagementFactory,
        usageProvider: any SubscriptionUsageProviding,
        snapshotHandler: @escaping @Sendable (ManagedSubscriptionUpdate) async -> Void
    ) {
        self.dataDirectoryURL = dataDirectoryURL
        self.secretStore = secretStore
        self.diagnostics = diagnostics
        self.serviceFactory = serviceFactory
        self.managementFactory = managementFactory
        self.usageProvider = usageProvider
        self.snapshotHandler = snapshotHandler
        self.snapshot = ManagedSubscriptionSnapshot(
            isUsageProviderAvailable: usageProvider.isAvailable
        )
    }

    fileprivate var currentUpdate: ManagedSubscriptionUpdate {
        ManagedSubscriptionUpdate(
            coordinatorID: id,
            revision: snapshotRevision,
            snapshot: snapshot
        )
    }

    func reconcile(configuration: CLIProxyConfiguration, suspended: Bool) async {
        self.configuration = configuration
        self.suspended = suspended
        guard configuration.enabled, !suspended else {
            await stop(clearAccounts: !configuration.enabled)
            return
        }

        do {
            let apiKey = try secretStore.ensureToken(for: configuration.endpointID)
            let password = try secretStore.ensureCLIProxyManagementPassword()
            if service == nil {
                service = serviceFactory(dataDirectoryURL) { [weak self] state in
                    Task { await self?.serviceStateChanged(state) }
                }
            }
            guard let service else { return }
            try await service.start(
                configuration: configuration,
                apiKey: apiKey,
                managementPassword: password
            )
            snapshot.runtimeState = await service.state
            snapshot.errorMessage = nil
            await publish()
            try? await refreshAccounts(reportErrors: false)
        } catch {
            snapshot.runtimeState = .failed(error.localizedDescription)
            snapshot.errorMessage = error.localizedDescription
            await publish()
            await diagnostics.append(
                subject: .gateway,
                severity: .error,
                category: "cliproxy.failed",
                summary: error.localizedDescription
            )
        }
    }

    func setSuspended(_ suspended: Bool) async {
        self.suspended = suspended
        guard let configuration else { return }
        await reconcile(configuration: configuration, suspended: suspended)
    }

    func shutdown() async {
        configuration = nil
        suspended = false
        await stop(clearAccounts: true)
    }

    func startLogin(_ provider: CLIProxyLoginProvider) async throws -> CLIProxyLoginSession {
        loginTask?.cancel()
        loginTask = nil
        restartTask?.cancel()
        restartTask = nil
        stabilityTask?.cancel()
        stabilityTask = nil
        restartAttempt = 0

        // `reconcile` records sidecar startup failures in the snapshot. Keep
        // that actionable failure instead of replacing it with the generic
        // unavailable error from `managementClient()`.
        if case let .failed(message) = snapshot.runtimeState {
            throw ManagedSubscriptionError.loginFailed(message)
        }
        let client = try managementClient()
        do {
            let login = try await client.startLogin(provider)
            snapshot.activeProvider = provider
            snapshot.activeLogin = login
            snapshot.errorMessage = nil
            await publish()
            loginTask = Task { [weak self] in
                await self?.pollLogin(state: login.state)
            }
            return login
        } catch {
            snapshot.activeProvider = nil
            snapshot.activeLogin = nil
            snapshot.errorMessage = error.localizedDescription
            await publish()
            throw error
        }
    }

    func cancelLogin() async {
        loginTask?.cancel()
        loginTask = nil
        if let state = snapshot.activeLogin?.state,
           let client = try? managementClient() {
            try? await client.cancelLogin(state: state)
        }
        snapshot.activeProvider = nil
        snapshot.activeLogin = nil
        await publish()
    }

    func refreshAccounts(reportErrors: Bool = true) async throws {
        guard configuration?.enabled == true else {
            snapshot.accounts = []
            snapshot.usage = [:]
            await publish()
            return
        }
        guard !snapshot.isRefreshingAccounts else { return }
        snapshot.isRefreshingAccounts = true
        await publish()
        do {
            snapshot.accounts = try await managementClient().accounts()
            if reportErrors { snapshot.errorMessage = nil }
        } catch {
            if reportErrors {
                snapshot.errorMessage = error.localizedDescription
                snapshot.isRefreshingAccounts = false
                await publish()
                throw error
            }
        }
        snapshot.isRefreshingAccounts = false
        await publish()
    }

    func refreshUsage() async {
        guard !snapshot.isRefreshingUsage else { return }
        let accounts = snapshot.accounts.filter { $0.provider.lowercased() == "codex" }
        guard !accounts.isEmpty, usageProvider.isAvailable else {
            snapshot.usage = [:]
            await publish()
            return
        }
        snapshot.isRefreshingUsage = true
        await publish()
        let values = await usageProvider.usage(for: accounts)
        snapshot.usage = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        snapshot.isRefreshingUsage = false
        await publish()
    }

    func removeAccount(_ account: CLIProxyAccount) async throws {
        do {
            try await managementClient().deleteAccount(named: account.name)
            try await refreshAccounts()
            snapshot.errorMessage = nil
            await publish()
        } catch {
            snapshot.errorMessage = error.localizedDescription
            await publish()
            throw error
        }
    }

    func setAccountEnabled(_ account: CLIProxyAccount, enabled: Bool) async throws {
        guard !snapshot.updatingAccountIDs.contains(account.id) else { return }
        snapshot.updatingAccountIDs.insert(account.id)
        await publish()
        do {
            try await managementClient().setAccountDisabled(account, disabled: !enabled)
            try await refreshAccounts()
            snapshot.errorMessage = nil
        } catch {
            snapshot.errorMessage = error.localizedDescription
            snapshot.updatingAccountIDs.remove(account.id)
            await publish()
            throw error
        }
        snapshot.updatingAccountIDs.remove(account.id)
        await publish()
    }

    private func stop(clearAccounts: Bool) async {
        loginTask?.cancel()
        loginTask = nil
        restartTask?.cancel()
        restartTask = nil
        stabilityTask?.cancel()
        stabilityTask = nil
        await service?.stop()
        snapshot.runtimeState = .stopped
        snapshot.activeLogin = nil
        snapshot.activeProvider = nil
        snapshot.isRefreshingAccounts = false
        snapshot.updatingAccountIDs = []
        snapshot.isRefreshingUsage = false
        if clearAccounts {
            snapshot.accounts = []
            snapshot.usage = [:]
        }
        await publish()
    }

    private func managementClient() throws -> any CLIProxyManaging {
        guard case .running = snapshot.runtimeState else {
            throw ManagedSubscriptionError.proxyUnavailable
        }
        guard let configuration else {
            throw ManagedSubscriptionError.proxyUnavailable
        }
        guard let password = try secretStore.cliProxyManagementPassword(), !password.isEmpty else {
            throw ManagedSubscriptionError.managementCredentialUnavailable
        }
        return managementFactory(configuration.listenPort, password)
    }

    private func pollLogin(state: String) async {
        do {
            let client = try managementClient()
            for _ in 0..<300 {
                try Task.checkCancellation()
                let status = try await client.loginStatus(state: state)
                switch status.status {
                case "ok":
                    snapshot.activeLogin = nil
                    snapshot.activeProvider = nil
                    loginTask = nil
                    try await refreshAccounts()
                    snapshot.errorMessage = nil
                    await publish()
                    return
                case "error":
                    throw ManagedSubscriptionError.loginFailed(
                        status.error ?? "Authentication failed."
                    )
                default:
                    try await Task.sleep(for: .seconds(1))
                }
            }
            throw ManagedSubscriptionError.loginTimedOut
        } catch is CancellationError {
            return
        } catch {
            snapshot.activeLogin = nil
            snapshot.activeProvider = nil
            loginTask = nil
            snapshot.errorMessage = error.localizedDescription
            await publish()
        }
    }

    private func serviceStateChanged(_ state: CLIProxyRuntimeState) async {
        // State callbacks cross actors through Tasks and can therefore arrive
        // after a newer lifecycle command. Reject stale start/stop callbacks
        // using the coordinator's desired state before publishing them.
        switch state {
        case .running where configuration?.enabled != true || suspended:
            return
        case .starting where configuration?.enabled != true || suspended:
            return
        case .starting where snapshot.runtimeState.isRunning:
            return
        case .stopped where configuration?.enabled == true && !suspended:
            return
        case .failed where configuration?.enabled != true || suspended:
            return
        case .failed where snapshot.runtimeState.isFailed:
            // A service can report the same startup failure through its
            // callback and then throw the richer launch error. The callback
            // crosses actors asynchronously, so it may arrive after
            // `reconcile` has recorded that thrown error. Do not let the late
            // callback replace its diagnostic context with a raw process
            // state message.
            return
        default:
            break
        }
        snapshot.runtimeState = state
        await publish()
        switch state {
        case .running:
            restartTask?.cancel()
            restartTask = nil
            stabilityTask?.cancel()
            stabilityTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.markStableIfRunning()
            }
        case .failed:
            stabilityTask?.cancel()
            stabilityTask = nil
            scheduleRestartIfNeeded()
        case .stopped:
            stabilityTask?.cancel()
            stabilityTask = nil
        case .starting:
            break
        }
    }

    private func markStableIfRunning() {
        guard case .running = snapshot.runtimeState else { return }
        restartAttempt = 0
        stabilityTask = nil
    }

    private func scheduleRestartIfNeeded() {
        guard configuration?.enabled == true,
              !suspended,
              restartAttempt < 5,
              restartTask == nil else { return }
        let delay = min(30, 1 << restartAttempt)
        restartAttempt += 1
        restartTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.performScheduledRestart()
        }
    }

    private func performScheduledRestart() async {
        restartTask = nil
        guard let configuration, !suspended else { return }
        await reconcile(configuration: configuration, suspended: false)
    }

    private func publish() async {
        snapshotRevision &+= 1
        // This await is the lifecycle completion barrier: a coordinator
        // command must not return before ModelMoorSession consumes its state.
        // Wrapping the handler in an unstructured Task reintroduces stale
        // snapshots after commands such as suspendRuntime().
        await snapshotHandler(currentUpdate)
    }
}

private extension CLIProxyRuntimeState {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

extension ModelMoorSession {
    public func startSubscriptionLogin(
        _ provider: CLIProxyLoginProvider
    ) async throws -> CLIProxyLoginSession {
        guard ownsRuntime() else {
            throw SessionError.runtimeOwnedElsewhere(owner: recordedRuntimeOwner())
        }
        if !snapshot.configuration.cliProxy.enabled {
            var candidate = snapshot.configuration
            candidate.cliProxy.enabled = true
            candidate.reconcileManagedCLIProxyEndpoint()
            _ = try secretStore().ensureToken(for: candidate.cliProxy.endpointID)
            _ = try secretStore().ensureCLIProxyManagementPassword()
            try await saveConfiguration(candidate)
        } else {
            await reconcileManagedSubscriptions()
        }
        let coordinator = subscriptionCoordinator()
        let login = try await coordinator.startLogin(provider)
        return login
    }

    public func cancelSubscriptionLogin() async {
        guard let coordinator = managedSubscriptionCoordinator else { return }
        await coordinator.cancelLogin()
    }

    public func refreshSubscriptionAccounts() async throws {
        guard ownsRuntime() else {
            throw SessionError.runtimeOwnedElsewhere(owner: recordedRuntimeOwner())
        }
        guard snapshot.configuration.cliProxy.enabled else { return }
        let coordinator = subscriptionCoordinator()
        try await coordinator.refreshAccounts()
    }

    public func refreshSubscriptionState() async throws {
        try await refreshSubscriptionAccounts()
        if snapshot.configuration.cliProxy.enabled {
            await inspectEndpoint(snapshot.configuration.cliProxy.endpointID)
        }
    }

    public func refreshSubscriptionUsage() async {
        guard ownsRuntime() else { return }
        guard snapshot.configuration.cliProxy.enabled else { return }
        let coordinator = subscriptionCoordinator()
        await coordinator.refreshUsage()
    }

    public func removeSubscriptionAccount(_ account: CLIProxyAccount) async throws {
        guard ownsRuntime() else {
            throw SessionError.runtimeOwnedElsewhere(owner: recordedRuntimeOwner())
        }
        let coordinator = subscriptionCoordinator()
        try await coordinator.removeAccount(account)
    }

    public func setSubscriptionAccountEnabled(
        _ account: CLIProxyAccount,
        enabled: Bool
    ) async throws {
        guard ownsRuntime() else {
            throw SessionError.runtimeOwnedElsewhere(owner: recordedRuntimeOwner())
        }
        let coordinator = subscriptionCoordinator()
        try await coordinator.setAccountEnabled(account, enabled: enabled)
    }

    func reconcileManagedSubscriptions() async {
        guard ownsRuntime() else {
            if let coordinator = managedSubscriptionCoordinator {
                managedSubscriptionCoordinatorID = nil
                managedSubscriptionSnapshotRevision = 0
                await coordinator.shutdown()
                managedSubscriptionCoordinator = nil
            }
            let replacement = ManagedSubscriptionSnapshot(
                isUsageProviderAvailable: subscriptionUsageProvider.isAvailable
            )
            if snapshot.subscriptions != replacement {
                snapshot.subscriptions = replacement
                emit()
            }
            return
        }
        let coordinator = subscriptionCoordinator()
        await coordinator.reconcile(
            configuration: snapshot.configuration.cliProxy,
            suspended: isRuntimeSuspended()
        )
    }

    private func subscriptionCoordinator() -> ManagedSubscriptionCoordinator {
        if let managedSubscriptionCoordinator { return managedSubscriptionCoordinator }
        let coordinator = ManagedSubscriptionCoordinator(
            dataDirectoryURL: cliProxyDataDirectoryURL(),
            secretStore: backgroundSecretStore(),
            diagnostics: diagnosticLog(),
            serviceFactory: cliProxyServiceFactory,
            managementFactory: cliProxyManagementFactory,
            usageProvider: subscriptionUsageProvider
        ) { [weak self] update in
            await self?.applyManagedSubscriptionUpdate(update)
        }
        managedSubscriptionCoordinator = coordinator
        managedSubscriptionCoordinatorID = coordinator.id
        managedSubscriptionSnapshotRevision = 0
        return coordinator
    }

    private func applyManagedSubscriptionUpdate(
        _ update: ManagedSubscriptionUpdate
    ) async {
        guard managedSubscriptionCoordinatorID == update.coordinatorID,
              update.revision >= managedSubscriptionSnapshotRevision else { return }
        managedSubscriptionSnapshotRevision = update.revision
        let subscriptions = update.snapshot
        let previous = snapshot.subscriptions
        guard previous != subscriptions else { return }
        snapshot.subscriptions = subscriptions
        emit()

        if previous.runtimeState != subscriptions.runtimeState
            || previous.accounts != subscriptions.accounts {
            if snapshot.configuration.cliProxy.enabled {
                await inspectEndpoint(snapshot.configuration.cliProxy.endpointID)
            }
            await reconcileGatewayAfterCredentialChange()
        }
    }
}
