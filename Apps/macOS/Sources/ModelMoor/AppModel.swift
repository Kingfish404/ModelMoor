import AppKit
import Foundation
import ModelMoorApplication
import ModelMoorCore
import ModelMoorSystem
import ModelMoorGateway
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration = ModelMoorConfiguration() {
        didSet {
            if oldValue.tunnels != configuration.tunnels
                || oldValue.endpoints != configuration.endpoints {
                sidebarSearchSourceRevision &+= 1
            }
        }
    }
    @Published var statuses: [UUID: TunnelStatus] = [:]
    @Published var inspections: [UUID: EndpointInspection] = [:] {
        didSet {
            if oldValue != inspections {
                sidebarSearchSourceRevision &+= 1
            }
        }
    }
    @Published var inspectingEndpointIDs: Set<UUID> = []
    @Published private(set) var isInspectingAllEndpoints = false
    @Published var gatewayState: GatewayServiceState = .stopped
    @Published private(set) var sessionRuntimeState: SessionRuntimeState = .stopped
    @Published private(set) var cliProxyState: CLIProxyRuntimeState = .stopped
    @Published private(set) var subscriptionAccounts: [CLIProxyAccount] = []
    @Published private(set) var activeSubscriptionLogin: CLIProxyLoginSession?
    @Published private(set) var activeSubscriptionProvider: CLIProxyLoginProvider?
    @Published private(set) var isRefreshingSubscriptionAccounts = false
    @Published private(set) var updatingSubscriptionAccountIDs: Set<String> = []
    @Published private(set) var subscriptionUsage: [String: SubscriptionUsageSnapshot] = [:]
    @Published private(set) var isRefreshingSubscriptionUsage = false
    @Published private(set) var isCodexBarAvailable = false
    @Published private(set) var tokenUsage = TokenUsageSnapshot.zero
    @Published var selectedTunnelID: UUID?
    @Published var selectedEndpointID: UUID?
    @Published var errorMessage: String?
    @Published var isLoaded = false
    @Published var launchAtLogin: Bool
    @Published private(set) var sshTargets: [SSHHostTarget] = []
    @Published private(set) var isRefreshingSSHTargets = false
    @Published private(set) var availableEndpointAPIKeyIDs: Set<UUID> = []
    @Published var lastSavedAt: Date?
    @Published var navigationRequest: NavigationSelection?
    @Published var addEndpointRequest = 0
    @Published var addSSHConnectionRequest = 0
    @Published var preferredModelEndpointID: UUID?
    @Published private(set) var isUpdatingGatewayAccess = false
    @Published private(set) var isUIRefreshActive = false
    private(set) var sidebarSearchSourceRevision: UInt64 = 0

    let runtimeProfile: ModelMoorRuntimeProfile
    /// Single persistent business entry point (docs/PLAN.md §4). AppModel only
    /// projects secret-free snapshots, manages drafts/navigation and performs
    /// AppKit presentation actions such as pasteboard and workspace opening.
    let session: ModelMoorSession
    private var sessionSubscription: Task<Void, Never>?
    private var lastSnapshotConfiguration: ModelMoorConfiguration?
    private var isApplyingSnapshotConfiguration = false
    /// Snapshot-driven: tunnels the runtime should be running. Read-only for
    /// views; mutate via session connect/disconnect commands.
    private var requestedTunnelIDs: Set<UUID> = []
    private var lastSubscriptionErrorMessage: String?
    private var usageRefreshTask: Task<Void, Never>?

    init(
        runtimeProfile: ModelMoorRuntimeProfile = .current,
        store: ConfigurationStore? = nil,
        inspector: any APIInspecting = APIInspector(),
        sshConfigScanner: any SSHConfigScanning = SSHConfigScanner(),
        tokenStore: KeychainTokenStore? = nil,
        tokenUsageStore: TokenUsageStore? = nil
    ) {
        let resolvedTokenStore = tokenStore ?? KeychainTokenStore(
            service: runtimeProfile.secretService,
            fallbackServices: runtimeProfile.legacySecretServices
        )
        let resolvedStore = store ?? ConfigurationStore(
            fileURL: runtimeProfile.configurationURL,
            legacyImportURL: runtimeProfile.legacyConfigurationURL,
            initialConfiguration: runtimeProfile.initialConfiguration,
            endpointCredentialLookup: { try resolvedTokenStore.token(for: $0) }
        )
        let resolvedUsageStore = tokenUsageStore ?? TokenUsageStore(fileURL: runtimeProfile.tokenUsageURL)
        self.runtimeProfile = runtimeProfile
        // The session shares this process's stores and the diagnostic log so
        // Copy Diagnostic Summary covers tunnel, endpoint and Gateway events
        // from both GUI and session paths.
        let sharedDiagnostics = DiagnosticLog()
        self.session = try! ModelMoorSession(
            profile: runtimeProfile,
            store: resolvedStore,
            secretStore: resolvedTokenStore,
            usageStore: resolvedUsageStore,
            inspector: inspector,
            sshConfigScanner: sshConfigScanner,
            diagnostics: sharedDiagnostics
        )
        self.launchAtLogin = runtimeProfile.supportsLaunchAtLogin
            && SMAppService.mainApp.status == .enabled
        subscribeToSession()
        Task {
            await load()
            await refreshSSHTargets()
        }
    }

    /// Projects session snapshots onto the published GUI state. Configuration
    /// is only overwritten when it changed upstream, so in-progress drafts are
    /// never clobbered by status-only emissions.
    private func subscribeToSession() {
        // Task inherits the MainActor from init, so snapshot projection lands
        // on the UI thread directly.
        sessionSubscription = Task { [weak self] in
            guard let self else { return }
            for await snapshot in session.snapshots() {
                self.applySnapshot(snapshot)
            }
        }
    }

    /// Deterministically applies the session's current snapshot after a
    /// command, instead of waiting for the asynchronous stream delivery.
    private func syncFromSession() async {
        applySnapshot(await session.snapshot)
    }

    private func applySnapshot(_ snapshot: AppSnapshot) {
        if snapshot.configuration != lastSnapshotConfiguration {
            lastSnapshotConfiguration = snapshot.configuration
            isApplyingSnapshotConfiguration = true
            configuration = snapshot.configuration
            isApplyingSnapshotConfiguration = false
        }
        if statuses != snapshot.tunnelStatuses {
            statuses = snapshot.tunnelStatuses
        }
        if gatewayState != snapshot.gatewayState {
            gatewayState = snapshot.gatewayState
        }
        if sessionRuntimeState != snapshot.runtimeState {
            sessionRuntimeState = snapshot.runtimeState
        }
        if inspections != snapshot.inspections {
            inspections = snapshot.inspections
        }
        if tokenUsage != snapshot.usage {
            tokenUsage = snapshot.usage
        }
        if sshTargets != snapshot.sshTargets {
            sshTargets = snapshot.sshTargets
        }
        if isRefreshingSSHTargets != snapshot.isRefreshingSSHTargets {
            isRefreshingSSHTargets = snapshot.isRefreshingSSHTargets
        }
        if availableEndpointAPIKeyIDs != snapshot.availableEndpointAPIKeyIDs {
            availableEndpointAPIKeyIDs = snapshot.availableEndpointAPIKeyIDs
        }
        let subscriptions = snapshot.subscriptions
        if cliProxyState != subscriptions.runtimeState {
            cliProxyState = subscriptions.runtimeState
        }
        if subscriptionAccounts != subscriptions.accounts {
            subscriptionAccounts = subscriptions.accounts
        }
        if activeSubscriptionLogin != subscriptions.activeLogin {
            activeSubscriptionLogin = subscriptions.activeLogin
        }
        if activeSubscriptionProvider != subscriptions.activeProvider {
            activeSubscriptionProvider = subscriptions.activeProvider
        }
        if isRefreshingSubscriptionAccounts != subscriptions.isRefreshingAccounts {
            isRefreshingSubscriptionAccounts = subscriptions.isRefreshingAccounts
        }
        if updatingSubscriptionAccountIDs != subscriptions.updatingAccountIDs {
            updatingSubscriptionAccountIDs = subscriptions.updatingAccountIDs
        }
        if subscriptionUsage != subscriptions.usage {
            subscriptionUsage = subscriptions.usage
        }
        if isRefreshingSubscriptionUsage != subscriptions.isRefreshingUsage {
            isRefreshingSubscriptionUsage = subscriptions.isRefreshingUsage
        }
        if isCodexBarAvailable != subscriptions.isUsageProviderAvailable {
            isCodexBarAvailable = subscriptions.isUsageProviderAvailable
        }
        if lastSubscriptionErrorMessage != subscriptions.errorMessage {
            lastSubscriptionErrorMessage = subscriptions.errorMessage
            if let message = subscriptions.errorMessage {
                errorMessage = message
            }
        }
        requestedTunnelIDs = snapshot.requestedTunnelIDs
    }

    var overallPhase: TunnelPhase {
        let requested = configuration.tunnels.filter { requestedTunnelIDs.contains($0.id) }
        if configuration.gateway.enabled {
            switch gatewayState {
            case .failed: return .failed
            case .running where configuration.routes.contains(where: { $0.enabled }):
                if requested.isEmpty { return .connected }
            case .stopped, .running: break
            }
        }
        guard !requested.isEmpty else { return .stopped }
        let phases = requested.map { statuses[$0.id]?.phase ?? .stopped }
        if phases.allSatisfy({ $0 == .connected }) { return .connected }
        if phases.contains(.waitingForNetwork) { return .waitingForNetwork }
        if phases.contains(.connecting) { return .connecting }
        if phases.contains(.disconnecting) { return .disconnecting }
        if phases.contains(.waitingToRetry) { return .waitingToRetry }
        if phases.contains(.failed) { return .failed }
        return .stopped
    }

    var subscriptionActionAvailability: ManagedSubscriptionActionAvailability {
        ManagedSubscriptionInteractionPolicy.availability(
            runtimeState: sessionRuntimeState,
            cliProxyState: cliProxyState,
            hasActiveLogin: activeSubscriptionLogin != nil
        )
    }

    var menuBarSymbol: String {
        switch overallPhase {
        case .connected: "anchor.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath.circle"
        case .waitingForNetwork: "wifi.slash"
        case .disconnecting: "stop.circle"
        case .waitingToRetry: "clock.arrow.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "anchor.circle"
        }
    }

    var summary: String {
        let connected = configuration.tunnels.filter { statuses[$0.id]?.phase == .connected }.count
        let enabled = requestedTunnelIDs.count
        let models = inspections.values.reduce(0) { $0 + ($1.models?.count ?? 0) }
        if configuration.gateway.enabled {
            switch gatewayState {
            case .stopped: return "Unified API stopped"
            case .failed: return "Unified API needs attention"
            case .running:
                let exposed = configuration.routes.filter(\.enabled).count
                return exposed == 1 ? "Unified API ready · 1 model" : "Unified API ready · \(exposed) models"
            }
        }
        if enabled == 0 { return "No active SSH connections" }
        if connected == enabled {
            let connections = enabled == 1 ? "1 connection" : "\(enabled) connections"
            return models > 0 ? "\(connections), \(models) models" : "\(connections) active"
        }
        return "\(connected) of \(enabled) connected"
    }

    func load() async {
        do {
            try await session.load()
            await syncFromSession()
            selectedTunnelID = configuration.tunnels.first?.id
            isLoaded = true
            do {
                try await session.startRuntime(owner: "\(runtimeProfile.displayName) app")
            } catch {
                // Another runtime (CLI/TUI) owns the lock: stay read-only.
                await session.refreshRuntimeState()
                errorMessage = error.localizedDescription
            }
        } catch {
            isLoaded = true
            errorMessage = error.localizedDescription
        }
    }

    func saveAndRestart() async {
        do {
            configuration.reconcileManagedCLIProxyEndpoint()
            try await session.saveConfiguration(configuration)
            await syncFromSession()
            errorMessage = nil
            lastSavedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshSSHTargets() async {
        do {
            _ = try await session.refreshSSHTargets()
            await syncFromSession()
        } catch {
            await syncFromSession()
            errorMessage = "Could not read SSH config: \(error.localizedDescription)"
        }
    }

    func requestAddEndpoint() {
        addEndpointRequest += 1
    }

    func requestAddSSHConnection() {
        addSSHConnectionRequest += 1
    }

    @discardableResult
    func createSSHConnection(
        name: String,
        sshHost: String,
        connectOnLaunch: Bool,
        firstMapping: PortMappingConfiguration
    ) async -> UUID? {
        let cleanHost = sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let tunnel = TunnelConfiguration(
            name: uniqueTunnelName(base: cleanName.isEmpty ? cleanHost : cleanName),
            sshHost: cleanHost,
            mappings: [firstMapping],
            connectOnLaunch: connectOnLaunch
        )
        var candidate = configuration
        candidate.tunnels.append(tunnel)
        do {
            try await session.saveConfiguration(candidate)
            await syncFromSession()
            selectedTunnelID = tunnel.id
            lastSavedAt = Date()
            errorMessage = nil
            navigationRequest = .connection(tunnel.id)
            if connectOnLaunch {
                try await session.connectTunnel(tunnel.id)
            }
            return tunnel.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func showEndpoint(_ id: UUID) {
        selectedEndpointID = id
        selectedTunnelID = nil
        navigationRequest = .endpoint(id)
    }

    func showConnection(_ id: UUID) {
        selectedEndpointID = nil
        selectedTunnelID = id
        navigationRequest = .connection(id)
    }

    func showGateway() {
        selectedEndpointID = nil
        selectedTunnelID = nil
        navigationRequest = .gateway
    }

    func showSubscriptionAccounts() {
        selectedEndpointID = nil
        selectedTunnelID = nil
        navigationRequest = .subscriptionAccounts
    }

    func showSettings() {
        selectedEndpointID = nil
        selectedTunnelID = nil
        navigationRequest = .settings
    }

    var canDuplicateSelectedEndpoint: Bool {
        guard let selectedEndpointID,
              let endpoint = configuration.endpoints.first(where: { $0.id == selectedEndpointID }) else {
            return false
        }
        return EndpointInteractionPolicy.canDuplicate(endpoint)
    }

    @discardableResult
    func duplicateEndpoint(_ endpointID: UUID) async -> UUID? {
        do {
            let copyID = try await session.duplicateEndpoint(endpointID)
            await syncFromSession()
            selectedEndpointID = copyID
            selectedTunnelID = nil
            navigationRequest = .endpoint(copyID)
            lastSavedAt = Date()
            errorMessage = nil
            return copyID
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func duplicateSelectedTunnel() async -> UUID? {
        guard let selectedTunnelID,
              let source = configuration.tunnels.first(where: { $0.id == selectedTunnelID }) else { return nil }
        var copy = source
        copy.id = UUID()
        copy.name = uniqueTunnelName(base: "\(source.name) copy")
        copy.connectOnLaunch = false
        copy.mappings = source.mappings.enumerated().map { offset, mapping in
            var result = mapping
            result.id = UUID()
            if result.direction.listensLocally {
                result.listenPort = nextAvailableLocalPort(startingAt: mapping.listenPort + offset + 1)
            }
            return result
        }
        var candidate = configuration
        candidate.tunnels.append(copy)
        do {
            try await session.saveConfiguration(candidate)
            await syncFromSession()
            self.selectedTunnelID = copy.id
            selectedEndpointID = nil
            navigationRequest = .connection(copy.id)
            lastSavedAt = Date()
            errorMessage = nil
            return copy.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func removeSelectedTunnel() async {
        guard let selectedTunnelID,
              configuration.tunnels.contains(where: { $0.id == selectedTunnelID }) else { return }
        do {
            _ = try await session.removeTunnel(selectedTunnelID)
            await syncFromSession()
            self.selectedTunnelID = configuration.tunnels.first?.id
            errorMessage = nil
            lastSavedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func addMapping(to tunnelID: UUID) -> UUID? {
        guard let index = configuration.tunnels.firstIndex(where: { $0.id == tunnelID }) else { return nil }
        let number = configuration.tunnels[index].mappings.count + 1
        var mapping = makeMapping(name: "Port \(number)")
        mapping.name = uniqueMappingName(mapping.name, in: configuration.tunnels[index])
        configuration.tunnels[index].mappings.append(mapping)
        return mapping.id
    }

    @discardableResult
    func duplicateMapping(_ mappingID: UUID, in tunnelID: UUID) -> UUID? {
        guard let tunnelIndex = configuration.tunnels.firstIndex(where: { $0.id == tunnelID }),
              let source = configuration.tunnels[tunnelIndex].mappings.first(where: { $0.id == mappingID }) else { return nil }
        var copy = source
        copy.id = UUID()
        copy.name = uniqueMappingName("\(source.name) copy", in: configuration.tunnels[tunnelIndex])
        if copy.direction.listensLocally {
            copy.listenPort = nextAvailableLocalPort(startingAt: source.listenPort + 1)
        } else {
            copy.listenPort += 1
        }
        configuration.tunnels[tunnelIndex].mappings.append(copy)
        return copy.id
    }

    func removeMapping(_ mappingID: UUID, from tunnelID: UUID) async {
        guard let tunnelIndex = configuration.tunnels.firstIndex(where: { $0.id == tunnelID }),
              configuration.tunnels[tunnelIndex].mappings.count > 1 else { return }
        do {
            _ = try await session.removeMapping(mappingID, fromTunnel: tunnelID)
            await syncFromSession()
            errorMessage = nil
            lastSavedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connectAll() async {
        guard canConnectAll else { return }
        do {
            try await session.saveConfiguration(configuration)
            try await session.connectAllTunnels()
            await syncFromSession()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnectAll() async {
        guard canDisconnectAll else { return }
        await session.disconnectAllTunnels()
    }

    func connect(_ id: UUID) async {
        guard let tunnel = configuration.tunnels.first(where: { $0.id == id }) else { return }
        let phase = status(for: id).phase
        guard ConnectionInteractionPolicy.canConnect(tunnel, phase: phase) else {
            guard (phase == .stopped || phase == .failed),
                  tunnel.enabledMappings.isEmpty else { return }
            errorMessage = "Enable at least one port mapping before connecting."
            return
        }
        do {
            try await session.saveConfiguration(configuration)
            try await session.connectTunnel(id)
            errorMessage = nil
            lastSavedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect(_ id: UUID) async {
        guard ConnectionInteractionPolicy.canDisconnect(phase: status(for: id).phase) else { return }
        await session.disconnectTunnel(id)
    }

    var canConnectAll: Bool {
        ConnectionInteractionPolicy.canConnectAll(
            tunnels: configuration.tunnels,
            statuses: statuses,
            requestedTunnelIDs: requestedTunnelIDs
        )
    }

    var canDisconnectAll: Bool {
        ConnectionInteractionPolicy.canDisconnectAll(requestedTunnelIDs: requestedTunnelIDs)
    }

    func inspectMappings(in tunnelID: UUID) async {
        guard let tunnel = configuration.tunnels.first(where: { $0.id == tunnelID }) else { return }
        let mappingIDs = Set(tunnel.mappings.map(\.id))
        for endpoint in configuration.endpoints where endpoint.enabled {
            guard case let .sshMapping(mappingID, _) = endpoint.source, mappingIDs.contains(mappingID) else { continue }
            await inspectEndpoint(endpoint.id)
        }
    }

    func inspectEndpoint(_ endpointID: UUID) async {
        guard let endpoint = configuration.endpoints.first(where: { $0.id == endpointID }),
              EndpointInteractionPolicy.canRefresh(
                  endpoint,
                  inspectingEndpointIDs: inspectingEndpointIDs
              ) else { return }
        inspectingEndpointIDs.insert(endpointID)
        defer { inspectingEndpointIDs.remove(endpointID) }
        await session.inspectEndpoint(endpointID)
    }

    func inspectAllEndpoints() async {
        guard !isInspectingAllEndpoints,
              EndpointInteractionPolicy.canRefreshAll(
                  endpoints: configuration.endpoints,
                  inspectingEndpointIDs: inspectingEndpointIDs
              ) else { return }
        isInspectingAllEndpoints = true
        let endpointIDs = Set(configuration.endpoints.lazy.filter(\.enabled).map(\.id))
        inspectingEndpointIDs.formUnion(endpointIDs)
        defer {
            inspectingEndpointIDs.subtract(endpointIDs)
            isInspectingAllEndpoints = false
        }
        await session.inspectAllEndpoints()
    }

    func isRecognizedLLMEndpoint(_ endpoint: APIEndpointConfiguration) -> Bool {
        guard endpoint.kind.isLLMAPI else { return false }
        return inspections[endpoint.id]?.classification != .otherHTTPService
    }

    @discardableResult
    func addDirectEndpoint(name: String, baseURL: String, token: String, deepSeek: Bool = false) async -> UUID? {
        do {
            let endpoint: APIEndpointConfiguration
            if deepSeek {
                endpoint = .deepSeek(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "DeepSeek" : name)
            } else {
                let parsed = try EndpointURLResolver.parseDirectBaseURL(baseURL)
                endpoint = APIEndpointConfiguration(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Direct API" : name,
                    source: .directHTTPS(originURL: parsed.origin),
                    basePath: parsed.basePath,
                    healthPath: parsed.basePath + "/models",
                    modelListPath: parsed.basePath + "/models",
                    authentication: .bearer
                )
            }
            let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
            try await session.addEndpoint(
                endpoint,
                secret: secret.isEmpty ? nil : secret
            )
            await syncFromSession()
            lastSavedAt = Date()
            errorMessage = nil
            return endpoint.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func testDirectEndpoint(
        name: String,
        baseURL: String,
        preset: EndpointPreset,
        token: String
    ) async -> EndpointInspection {
        do {
            let endpoint = try makeDirectEndpoint(name: name, baseURL: baseURL, preset: preset)
            return await session.inspectTemporaryEndpoint(endpoint, secret: token)
        } catch {
            return EndpointInspection(endpointID: UUID(), url: nil, errorMessage: error.localizedDescription)
        }
    }

    @discardableResult
    func createDirectEndpoint(
        name: String,
        baseURL: String,
        preset: EndpointPreset,
        token: String
    ) async -> UUID? {
        do {
            let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
            var endpoint = try makeDirectEndpoint(name: name, baseURL: baseURL, preset: preset)
            if preset == .openAI && secret.isEmpty {
                endpoint.authentication = .none
                endpoint.apiKeys = []
                endpoint.activeAPIKeyID = nil
            }
            try await session.addEndpoint(
                endpoint,
                secret: secret.isEmpty ? nil : secret
            )
            await syncFromSession()
            lastSavedAt = Date()
            errorMessage = nil
            navigationRequest = .endpoint(endpoint.id)
            await inspectEndpoint(endpoint.id)
            return endpoint.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func createSSHEndpoint(
        name: String,
        sshHost: String,
        remotePort: Int,
        preset: EndpointPreset,
        token: String
    ) async -> UUID? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHost = sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else {
            errorMessage = "Choose an SSH host before creating the endpoint."
            return nil
        }

        let mapping = PortMappingConfiguration(
            name: cleanName.isEmpty ? "LLM API" : cleanName,
            listenPort: nextAvailableLocalPort(),
            destinationPort: remotePort
        )
        var endpoint = makeEndpoint(
            id: UUID(),
            name: cleanName.isEmpty ? cleanHost : cleanName,
            source: .sshMapping(mappingID: mapping.id, originScheme: .http),
            preset: preset
        )
        let tunnel = TunnelConfiguration(
            name: uniqueTunnelName(base: cleanName.isEmpty ? cleanHost : cleanName),
            sshHost: cleanHost,
            mappings: [mapping]
        )
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if preset == .openAI && secret.isEmpty {
            endpoint.authentication = .none
            endpoint.apiKeys = []
            endpoint.activeAPIKeyID = nil
        }
        do {
            try await session.addSSHEndpoint(
                endpoint,
                tunnel: tunnel,
                secret: secret.isEmpty ? nil : secret
            )
            await syncFromSession()
            selectedTunnelID = tunnel.id
            lastSavedAt = Date()
            errorMessage = nil
            navigationRequest = .endpoint(endpoint.id)
            do {
                try await session.connectTunnel(tunnel.id)
            } catch {
                errorMessage = error.localizedDescription
            }
            return endpoint.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func applyEndpoint(_ endpoint: APIEndpointConfiguration) async -> Bool {
        guard let index = configuration.endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return false }
        var candidate = configuration
        candidate.endpoints[index] = endpoint
        do {
            try await session.saveConfiguration(candidate)
            await syncFromSession()
            lastSavedAt = Date()
            errorMessage = nil
            await inspectEndpoint(endpoint.id)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func applyTunnel(_ tunnel: TunnelConfiguration) async -> Bool {
        guard let index = configuration.tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return false }
        var candidate = configuration
        candidate.tunnels[index] = tunnel
        do {
            try await session.saveConfiguration(candidate)
            await syncFromSession()
            lastSavedAt = Date()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func addRoutes(_ routes: [(publicModel: String, upstreamModel: String)], endpointID: UUID) async -> Bool {
        var candidate = configuration
        for route in routes {
            candidate.routes.append(ModelRouteConfiguration(
                publicModel: route.publicModel.trimmingCharacters(in: .whitespacesAndNewlines),
                endpointID: endpointID,
                upstreamModel: route.upstreamModel.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        do {
            try await session.saveConfiguration(candidate)
            await syncFromSession()
            lastSavedAt = Date()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func saveGateway() async -> Bool {
        do {
            try await session.saveConfiguration(configuration)
            await syncFromSession()
            lastSavedAt = Date()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeEndpoint(_ endpointID: UUID) async {
        do {
            _ = try await session.removeEndpoint(endpointID)
            await syncFromSession()
            errorMessage = nil
            lastSavedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addRoute(publicModel: String, endpointID: UUID, upstreamModel: String) {
        configuration.routes.append(ModelRouteConfiguration(
            publicModel: publicModel.trimmingCharacters(in: .whitespacesAndNewlines),
            endpointID: endpointID,
            upstreamModel: upstreamModel.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }

    func removeRoute(_ routeID: UUID) {
        configuration.routes.removeAll { $0.id == routeID }
    }

    func endpointURL(_ endpoint: APIEndpointConfiguration) -> URL? {
        try? EndpointURLResolver.resolve(endpoint, mappings: mappingIndex)
    }

    func copyGatewayURL() {
        copy("http://127.0.0.1:\(configuration.gateway.listenPort)/v1")
    }

    func connectSubscriptionAccount(_ provider: CLIProxyLoginProvider) async {
        do {
            let login = try await session.startSubscriptionLogin(provider)
            await syncFromSession()
            lastSavedAt = Date()
            errorMessage = nil
            NSWorkspace.shared.open(login.url)
        } catch {
            await syncFromSession()
            errorMessage = error.localizedDescription
        }
    }

    func cancelSubscriptionLogin() async {
        await session.cancelSubscriptionLogin()
        await syncFromSession()
    }

    func refreshSubscriptionAccounts(showErrors: Bool = true) async {
        do {
            try await session.refreshSubscriptionAccounts()
            await syncFromSession()
            if showErrors { errorMessage = nil }
        } catch {
            await syncFromSession()
            if showErrors { errorMessage = error.localizedDescription }
        }
    }

    func refreshSubscriptionAccountState(showErrors: Bool = true) async {
        do {
            try await session.refreshSubscriptionState()
            await syncFromSession()
            if showErrors { errorMessage = nil }
        } catch {
            await syncFromSession()
            if showErrors { errorMessage = error.localizedDescription }
        }
    }

    func refreshSubscriptionUsage() async {
        await session.refreshSubscriptionUsage()
        await syncFromSession()
    }

    func removeSubscriptionAccount(_ account: CLIProxyAccount) async {
        do {
            try await session.removeSubscriptionAccount(account)
            await syncFromSession()
            errorMessage = nil
        } catch {
            await syncFromSession()
            errorMessage = error.localizedDescription
        }
    }

    func setSubscriptionAccountEnabled(_ account: CLIProxyAccount, enabled: Bool) async {
        do {
            try await session.setSubscriptionAccountEnabled(account, enabled: enabled)
            await syncFromSession()
            errorMessage = nil
        } catch {
            await syncFromSession()
            errorMessage = error.localizedDescription
        }
    }

    func copySubscriptionLoginCode() {
        guard let code = activeSubscriptionLogin?.userCode else { return }
        copy(code)
    }

    func copyGatewayToken() async {
        guard let key = configuration.gateway.apiKeys.first(where: \.enabled)
                ?? configuration.gateway.apiKeys.first else {
            errorMessage = "No Unified API key is configured."
            return
        }
        await copyGatewayAPIKey(key.id)
    }

    func copyGatewayAPIKey(_ keyID: UUID) async {
        guard !isUpdatingGatewayAccess else { return }
        isUpdatingGatewayAccess = true
        defer { isUpdatingGatewayAccess = false }
        do {
            copy(try await session.revealGatewayAPIKey(keyID))
            errorMessage = nil
        }
        catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func createGatewayAPIKey(name: String) async -> Bool {
        guard !isUpdatingGatewayAccess else { return false }
        isUpdatingGatewayAccess = true
        defer { isUpdatingGatewayAccess = false }
        do {
            let secret = try await session.createGatewayAPIKey(name: name)
            copy(secret)
            await syncFromSession()
            lastSavedAt = Date()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setGatewayRequiresAPIKey(_ required: Bool) async {
        guard !isUpdatingGatewayAccess else { return }
        isUpdatingGatewayAccess = true
        defer { isUpdatingGatewayAccess = false }
        do {
            try await session.setGatewayRequiresAPIKey(required)
            await syncFromSession()
            lastSavedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setGatewayAPIKeyEnabled(_ keyID: UUID, enabled: Bool) async {
        guard !isUpdatingGatewayAccess else { return }
        isUpdatingGatewayAccess = true
        defer { isUpdatingGatewayAccess = false }
        do {
            try await session.setGatewayAPIKeyEnabled(keyID, enabled: enabled)
            await syncFromSession()
            lastSavedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rotateGatewayAPIKey(_ keyID: UUID) async {
        guard configuration.gateway.apiKeys.contains(where: { $0.id == keyID }) else { return }
        guard !isUpdatingGatewayAccess else { return }
        isUpdatingGatewayAccess = true
        defer { isUpdatingGatewayAccess = false }
        do {
            let replacement = try await session.rotateGatewayAPIKey(keyID)
            copy(replacement)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeGatewayAPIKey(_ keyID: UUID) async {
        guard !isUpdatingGatewayAccess else { return }
        isUpdatingGatewayAccess = true
        defer { isUpdatingGatewayAccess = false }
        do {
            try await session.removeGatewayAPIKey(keyID)
            await syncFromSession()
            lastSavedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func hasToken(for endpointID: UUID) -> Bool {
        guard let endpoint = configuration.endpoints.first(where: { $0.id == endpointID }) else {
            return false
        }
        return EndpointInteractionPolicy.hasRequiredCredential(
            endpoint,
            availableAPIKeyIDs: availableEndpointAPIKeyIDs
        )
    }

    func hasToken(forAPIKey keyID: UUID) -> Bool {
        availableEndpointAPIKeyIDs.contains(keyID)
    }

    func createEndpointAPIKey(
        endpointID: UUID,
        name: String,
        secret: String
    ) async -> Bool {
        do {
            _ = try await session.createEndpointAPIKey(
                endpointID: endpointID,
                name: name,
                secret: secret
            )
            await syncFromSession()
            lastSavedAt = Date()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func replaceEndpointAPIKey(_ keyID: UUID, endpointID: UUID, secret: String) async -> Bool {
        guard configuration.endpoints.contains(where: {
            $0.id == endpointID && $0.apiKeys.contains(where: { $0.id == keyID })
        }) else { return false }
        let cleanSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSecret.isEmpty else {
            errorMessage = "Enter an API key."
            return false
        }
        do {
            try await session.replaceEndpointAPIKey(keyID, endpointID: endpointID, secret: cleanSecret)
            await syncFromSession()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func selectEndpointAPIKey(_ keyID: UUID, endpointID: UUID) async {
        do {
            try await session.selectEndpointAPIKey(keyID, endpointID: endpointID)
            await syncFromSession()
            lastSavedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeEndpointAPIKey(_ keyID: UUID, endpointID: UUID) async {
        guard configuration.endpoints.contains(where: { $0.id == endpointID }) else { return }
        do {
            try await session.removeEndpointAPIKey(keyID, endpointID: endpointID)
            await syncFromSession()
            lastSavedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func status(for id: UUID) -> TunnelStatus {
        statuses[id] ?? TunnelStatus(tunnelID: id, phase: .stopped, message: "Stopped")
    }

    func target(for alias: String) -> SSHHostTarget? {
        sshTargets.first { $0.alias.caseInsensitiveCompare(alias) == .orderedSame }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard runtimeProfile.supportsLaunchAtLogin else {
            launchAtLogin = false
            return
        }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorMessage = error.localizedDescription
        }
    }

    func shutdown() async {
        usageRefreshTask?.cancel()
        usageRefreshTask = nil
        isUIRefreshActive = false
        sessionSubscription?.cancel()
        sessionSubscription = nil
        await session.stopRuntime()
    }

    func setUIRefreshActive(_ active: Bool) {
        guard active != isUIRefreshActive else { return }
        isUIRefreshActive = active
        if active {
            usageRefreshTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await self?.session.refreshUsage()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        } else {
            usageRefreshTask?.cancel()
            usageRefreshTask = nil
        }
    }

    func prepareForSleep() async {
        await session.suspendRuntime(reason: "Waiting for Mac to wake")
        await syncFromSession()
    }

    func resumeAfterWake() async {
        await session.resumeRuntime()
        await syncFromSession()
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func dismissError() {
        errorMessage = nil
    }

    func copyDiagnosticSummary() async {
        let value = await session.diagnosticSummary()
        copy(value.isEmpty ? "ModelMoor has no diagnostic events yet." : value)
    }

    func openPersistenceDirectory(_ directoryURL: URL) {
        do {
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            guard NSWorkspace.shared.open(directoryURL) else {
                throw PersistenceLocationError.couldNotOpen(directoryURL.path)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openKeychainAccess() {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.keychainaccess"
        ), NSWorkspace.shared.open(applicationURL) else {
            errorMessage = PersistenceLocationError.keychainAccessUnavailable.localizedDescription
            return
        }
        errorMessage = nil
    }

    func tunnelBinding(id: UUID) -> Binding<TunnelConfiguration>? {
        guard let index = configuration.tunnels.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.configuration.tunnels[index] },
            set: { self.configuration.tunnels[index] = $0 }
        )
    }

    func endpointBinding(id: UUID) -> Binding<APIEndpointConfiguration>? {
        guard let index = configuration.endpoints.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.configuration.endpoints[index] },
            set: { self.configuration.endpoints[index] = $0 }
        )
    }

    func tokenUsageReport(
        from startDate: Date,
        to endDate: Date,
        bucketInterval: TimeInterval,
        routeID: UUID?,
        endpointID: UUID?
    ) async -> TokenUsageReport? {
        do {
            return try await session.tokenUsageReport(
                from: startDate,
                to: endDate,
                bucketInterval: bucketInterval,
                routeID: routeID,
                endpointID: endpointID
            )
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    private var mappingIndex: [UUID: PortMappingConfiguration] {
        Dictionary(uniqueKeysWithValues: configuration.tunnels.flatMap(\.mappings).map { ($0.id, $0) })
    }

    private func makeDirectEndpoint(
        name: String,
        baseURL: String,
        preset: EndpointPreset
    ) throws -> APIEndpointConfiguration {
        let parsed = try EndpointURLResolver.parseDirectBaseURL(baseURL)
        return makeEndpoint(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Direct API" : name,
            source: .directHTTPS(originURL: parsed.origin),
            preset: preset,
            parsedBasePath: parsed.basePath
        )
    }

    private func makeEndpoint(
        id: UUID,
        name: String,
        source: APIEndpointSource,
        preset: EndpointPreset,
        parsedBasePath: String = ""
    ) -> APIEndpointConfiguration {
        switch preset {
        case .deepSeek:
            let basePath = parsedBasePath
            let modelPath = basePath + "/models"
            return APIEndpointConfiguration(
                id: id,
                name: name,
                source: source,
                kind: .openAICompatible,
                basePath: basePath,
                healthPath: modelPath,
                modelListPath: modelPath,
                authentication: .bearer
            )
        case .openAI:
            let basePath = parsedBasePath.isEmpty ? "/v1" : parsedBasePath
            return APIEndpointConfiguration(
                id: id,
                name: name,
                source: source,
                kind: .openAICompatible,
                basePath: basePath,
                healthPath: basePath + "/models",
                modelListPath: basePath + "/models",
                authentication: .bearer
            )
        case .ollama:
            return APIEndpointConfiguration(
                id: id,
                name: name,
                source: source,
                kind: .ollama,
                basePath: parsedBasePath,
                healthPath: "/api/tags",
                modelListPath: "/api/tags",
                authentication: .none
            )
        case .custom:
            let healthPath = parsedBasePath.isEmpty ? "/" : parsedBasePath
            return APIEndpointConfiguration(
                id: id,
                name: name,
                source: source,
                kind: .customHTTP,
                basePath: parsedBasePath,
                healthPath: healthPath,
                modelListPath: nil,
                authentication: .none
            )
        }
    }

    private func makeMapping(name: String) -> PortMappingConfiguration {
        PortMappingConfiguration(name: name, listenPort: nextAvailableLocalPort())
    }

    private func nextAvailableLocalPort(startingAt initialPort: Int = 18_888) -> Int {
        let used = Set(configuration.tunnels.flatMap(\.mappings).filter { $0.direction.listensLocally }.map(\.listenPort))
        var port = min(max(initialPort, 1), 65_535)
        while used.contains(port), port < 65_535 { port += 1 }
        return port
    }

    private func uniqueTunnelName(base: String) -> String {
        let names = Set(configuration.tunnels.map { $0.name.lowercased() })
        guard names.contains(base.lowercased()) else { return base }
        var index = 2
        while names.contains("\(base) \(index)".lowercased()) { index += 1 }
        return "\(base) \(index)"
    }

    private func uniqueMappingName(_ base: String, in tunnel: TunnelConfiguration) -> String {
        let names = Set(tunnel.mappings.map { $0.name.lowercased() })
        guard names.contains(base.lowercased()) else { return base }
        var index = 2
        while names.contains("\(base) \(index)".lowercased()) { index += 1 }
        return "\(base) \(index)"
    }
}

private enum PersistenceLocationError: LocalizedError {
    case couldNotOpen(String)
    case keychainAccessUnavailable

    var errorDescription: String? {
        switch self {
        case let .couldNotOpen(path):
            "Could not open the persistence folder: \(path)"
        case .keychainAccessUnavailable:
            "Keychain Access could not be opened on this Mac."
        }
    }
}
