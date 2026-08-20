import AppKit
import Foundation
import ModelMoorCore
import ModelMoorGateway
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    private static let endpointInspectionConcurrency = 4

    @Published var configuration = ModelMoorConfiguration()
    @Published var statuses: [UUID: TunnelStatus] = [:]
    @Published var inspections: [UUID: EndpointInspection] = [:]
    @Published var inspectingEndpointIDs: Set<UUID> = []
    @Published var gatewayState: GatewayServiceState = .stopped
    @Published var cliProxyState: CLIProxyRuntimeState = .stopped
    @Published private(set) var subscriptionAccounts: [CLIProxyAccount] = []
    @Published private(set) var activeSubscriptionLogin: CLIProxyLoginSession?
    @Published private(set) var activeSubscriptionProvider: CLIProxyLoginProvider?
    @Published private(set) var isRefreshingSubscriptionAccounts = false
    @Published private(set) var updatingSubscriptionAccountIDs: Set<String> = []
    @Published private(set) var subscriptionUsage: [String: SubscriptionUsageSnapshot] = [:]
    @Published private(set) var isRefreshingSubscriptionUsage = false
    @Published private(set) var tokenUsage = TokenUsageSnapshot.zero
    @Published var selectedTunnelID: UUID?
    @Published var selectedEndpointID: UUID?
    @Published var errorMessage: String?
    @Published var isLoaded = false
    @Published var launchAtLogin: Bool
    @Published var sshTargets: [SSHHostTarget] = []
    @Published var isRefreshingSSHTargets = false
    @Published var lastSavedAt: Date?
    @Published var navigationRequest: NavigationSelection?
    @Published var addEndpointRequest = 0
    @Published var addSSHConnectionRequest = 0
    @Published var preferredModelEndpointID: UUID?
    @Published private(set) var isUpdatingGatewayAccess = false
    @Published private(set) var isUIRefreshActive = false

    private let store: ConfigurationStore
    let runtimeProfile: ModelMoorRuntimeProfile
    private let inspector: any APIInspecting
    private let tokenStore: KeychainTokenStore
    private let backgroundTokenStore: KeychainTokenStore
    private let deletionCoordinator: ConfigurationDeletionCoordinator
    private let tokenUsageStore: TokenUsageStore
    private let codexBarUsageService: CodexBarUsageService
    private let diagnosticLog = DiagnosticLog()
    private var service: TunnelService?
    private var gatewayCoordinator: GatewayServiceCoordinator?
    private var cliProxyService: CLIProxyService?
    private var subscriptionLoginTask: Task<Void, Never>?
    private var cliProxyRestartTask: Task<Void, Never>?
    private var cliProxyStabilityTask: Task<Void, Never>?
    private var cliProxyRestartAttempt = 0
    private var runtimeOwnership: RuntimeOwnership?
    private var requestedTunnelIDs: Set<UUID> = []
    private var networkMonitor: NetworkMonitor?
    private var networkAvailable = false
    private var sleeping = false
    private var inspectionTasks: [UUID: Task<EndpointInspection, Never>] = [:]
    private var usageRefreshTask: Task<Void, Never>?
    private var tokenAvailability: [UUID: Bool] = [:]

    init(
        runtimeProfile: ModelMoorRuntimeProfile = .current,
        store: ConfigurationStore? = nil,
        inspector: any APIInspecting = APIInspector(),
        tokenStore: KeychainTokenStore? = nil,
        tokenUsageStore: TokenUsageStore? = nil
    ) {
        let resolvedTokenStore = tokenStore ?? KeychainTokenStore(
            service: runtimeProfile.keychainService,
            fallbackServices: runtimeProfile.legacyKeychainServices
        )
        let resolvedStore = store ?? ConfigurationStore(
            fileURL: runtimeProfile.configurationURL,
            legacyImportURL: runtimeProfile.legacyConfigurationURL,
            initialConfiguration: runtimeProfile.initialConfiguration,
            endpointCredentialLookup: { try resolvedTokenStore.token(for: $0) }
        )
        self.runtimeProfile = runtimeProfile
        self.store = resolvedStore
        self.inspector = inspector
        self.tokenStore = resolvedTokenStore
        self.backgroundTokenStore = resolvedTokenStore.disallowingUserInteraction()
        self.tokenUsageStore = tokenUsageStore ?? TokenUsageStore(fileURL: runtimeProfile.tokenUsageURL)
        self.codexBarUsageService = CodexBarUsageService(
            authDirectoryURL: runtimeProfile.cliProxyDataDirectoryURL.appendingPathComponent("auths", isDirectory: true)
        )
        self.deletionCoordinator = ConfigurationDeletionCoordinator(
            store: resolvedStore,
            secretStore: resolvedTokenStore
        )
        self.launchAtLogin = runtimeProfile.supportsLaunchAtLogin
            && SMAppService.mainApp.status == .enabled
        let monitor = NetworkMonitor { [weak self] availability in
            Task { @MainActor [weak self] in
                await self?.networkAvailabilityChanged(availability)
            }
        }
        self.networkMonitor = monitor
        monitor.start()
        Task {
            await load()
            await refreshSSHTargets()
        }
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
        let models = inspections.values.compactMap(\.models).flatMap { $0 }.count
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
            configuration = try await store.load()
            await refreshTokenUsage()
            selectedTunnelID = configuration.tunnels.first?.id
            isLoaded = true
            requestedTunnelIDs = Set(configuration.tunnels.filter(\.connectOnLaunch).map(\.id))
            try ensureService()
            await applyRuntimeAvailability()
            await reconcileService()
            await reconcileCLIProxy()
            await reconcileGateway()
        } catch {
            isLoaded = true
            errorMessage = error.localizedDescription
        }
    }

    func saveAndRestart() async {
        do {
            configuration.reconcileManagedCLIProxyEndpoint()
            try await store.save(configuration)
            errorMessage = nil
            lastSavedAt = Date()
            requestedTunnelIDs.formIntersection(configuration.tunnels.map(\.id))
            try ensureService()
            await applyRuntimeAvailability()
            await reconcileService()
            await reconcileCLIProxy()
            await reconcileGateway()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshSSHTargets() async {
        isRefreshingSSHTargets = true
        defer { isRefreshingSSHTargets = false }
        do {
            sshTargets = try await Task.detached(priority: .utility) {
                try SSHConfigScanner().discoverTargets()
            }.value
        } catch {
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
            try await store.save(candidate)
            configuration = candidate
            selectedTunnelID = tunnel.id
            lastSavedAt = Date()
            errorMessage = nil
            navigationRequest = .connection(tunnel.id)
            if connectOnLaunch {
                try ensureService()
                requestedTunnelIDs.insert(tunnel.id)
                await applyRuntimeAvailability()
                await service?.start(tunnel)
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
        if case .directHTTPS = endpoint.source { return true }
        return false
    }

    @discardableResult
    func duplicateEndpoint(_ endpointID: UUID) async -> UUID? {
        guard let source = configuration.endpoints.first(where: { $0.id == endpointID }) else { return nil }
        guard case .directHTTPS = source.source else {
            errorMessage = "API endpoints provided over SSH cannot be duplicated."
            return nil
        }
        do {
            var copy = source
            copy.id = UUID()
            copy.name = uniqueEndpointName(base: "\(source.name) copy")
            let keyIDMap = Dictionary(uniqueKeysWithValues: source.apiKeys.map { key in
                (key.id, key.id == source.id ? copy.id : UUID())
            })
            copy.apiKeys = source.apiKeys.map { key in
                EndpointAPIKeyConfiguration(id: keyIDMap[key.id]!, name: key.name)
            }
            copy.activeAPIKeyID = source.activeAPIKeyID.flatMap { keyIDMap[$0] }
            let credentials = try source.apiKeys.map { key in
                (id: keyIDMap[key.id]!, secret: try tokenStore.token(for: key.id))
            }
            var candidate = configuration
            candidate.endpoints.append(copy)
            _ = try candidate.validated()
            var writtenCredentialIDs: [UUID] = []
            do {
                for credential in credentials where credential.secret?.isEmpty == false {
                    try tokenStore.setToken(credential.secret, for: credential.id)
                    writtenCredentialIDs.append(credential.id)
                }
                try await store.save(candidate)
            } catch {
                for credentialID in writtenCredentialIDs {
                    try? tokenStore.setToken(nil, for: credentialID)
                }
                throw error
            }
            configuration = candidate
            selectedEndpointID = copy.id
            selectedTunnelID = nil
            navigationRequest = .endpoint(copy.id)
            lastSavedAt = Date()
            errorMessage = nil
            if copy.enabled { await inspectEndpoint(copy.id) }
            await reconcileGateway()
            return copy.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func duplicateSelectedTunnel() {
        guard let selectedTunnelID,
              let source = configuration.tunnels.first(where: { $0.id == selectedTunnelID }) else { return }
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
        configuration.tunnels.append(copy)
        self.selectedTunnelID = copy.id
    }

    func removeSelectedTunnel() async {
        guard let selectedTunnelID,
              configuration.tunnels.contains(where: { $0.id == selectedTunnelID }) else { return }
        do {
            let result = try await deletionCoordinator.removeTunnel(selectedTunnelID, from: configuration)
            configuration = result.configuration
            requestedTunnelIDs.remove(selectedTunnelID)
            for id in result.removedMappingIDs.union(result.removedEndpointIDs) { inspections[id] = nil }
            statuses[selectedTunnelID] = nil
            self.selectedTunnelID = configuration.tunnels.first?.id
            await service?.stop(selectedTunnelID)
            await reconcileService()
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
            let result = try await deletionCoordinator.removeMapping(
                mappingID,
                fromTunnel: tunnelID,
                in: configuration
            )
            configuration = result.configuration
            for id in result.removedMappingIDs.union(result.removedEndpointIDs) { inspections[id] = nil }
            await reconcileService()
            errorMessage = nil
            lastSavedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connectAll() async {
        do {
            try await store.save(configuration)
            try ensureService()
            await applyRuntimeAvailability()
            requestedTunnelIDs = Set(configuration.tunnels.filter { !$0.enabledMappings.isEmpty }.map(\.id))
            await reconcileService()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnectAll() async {
        requestedTunnelIDs.removeAll()
        await service?.stopAll()
    }

    func connect(_ id: UUID) async {
        do {
            try await store.save(configuration)
            guard let tunnel = configuration.tunnels.first(where: { $0.id == id }) else { return }
            guard !tunnel.enabledMappings.isEmpty else {
                errorMessage = "Enable at least one port mapping before connecting."
                return
            }
            try ensureService()
            await applyRuntimeAvailability()
            requestedTunnelIDs.insert(id)
            await service?.start(tunnel)
            errorMessage = nil
            lastSavedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect(_ id: UUID) async {
        requestedTunnelIDs.remove(id)
        await service?.stop(id)
    }

    func inspectMappings(in tunnelID: UUID) async {
        await inspectEndpoints(forTunnel: tunnelID)
    }

    func inspectEndpoint(_ endpointID: UUID) async {
        guard let endpoint = configuration.endpoints.first(where: { $0.id == endpointID }) else { return }
        inspectingEndpointIDs.insert(endpointID)
        defer { inspectingEndpointIDs.remove(endpointID) }
        let secret = endpoint.activeAPIKeyID.flatMap { try? backgroundTokenStore.token(for: $0) }
        inspectionTasks[endpointID]?.cancel()
        let mappings = mappingIndex
        let task = Task { [inspector] in
            await inspector.inspect(endpoint, mappings: mappings, secret: secret)
        }
        inspectionTasks[endpointID] = task
        let inspection = await task.value
        inspectionTasks[endpointID] = nil
        guard !sleeping else { return }
        inspections[endpointID] = inspection
        await recordInspection(inspection, endpointID: endpointID)
    }

    func inspectAllEndpoints() async {
        let connectedTunnelIDs = Set(statuses.values.compactMap { status in
            status.phase == .connected ? status.tunnelID : nil
        })
        let connectedMappingIDs = Set(configuration.tunnels.lazy
            .filter { connectedTunnelIDs.contains($0.id) }
            .flatMap(\.mappings)
            .map(\.id))
        let endpointIDs = configuration.endpoints.compactMap { endpoint -> UUID? in
            guard endpoint.enabled else { return nil }
            if case let .sshMapping(mappingID, _) = endpoint.source,
               !connectedMappingIDs.contains(mappingID) {
                return nil
            }
            return endpoint.id
        }

        await withTaskGroup(of: Void.self) { group in
            var iterator = endpointIDs.makeIterator()
            for _ in 0..<min(Self.endpointInspectionConcurrency, endpointIDs.count) {
                guard let endpointID = iterator.next() else { break }
                group.addTask { [weak self] in
                    await self?.inspectEndpoint(endpointID)
                }
            }
            while await group.next() != nil {
                guard let endpointID = iterator.next() else { continue }
                group.addTask { [weak self] in
                    await self?.inspectEndpoint(endpointID)
                }
            }
        }
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
            configuration = try await deletionCoordinator.addEndpoint(
                endpoint,
                secret: secret.isEmpty ? nil : secret,
                to: configuration
            )
            lastSavedAt = Date()
            await reconcileGateway()
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
            return await inspector.inspect(
                endpoint,
                mappings: [:],
                secret: token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : token
            )
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
            configuration = try await deletionCoordinator.addEndpoint(
                endpoint,
                secret: secret.isEmpty ? nil : secret,
                to: configuration
            )
            lastSavedAt = Date()
            errorMessage = nil
            navigationRequest = .endpoint(endpoint.id)
            await inspectEndpoint(endpoint.id)
            await reconcileGateway()
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
        var candidate = configuration
        candidate.tunnels.append(tunnel)
        candidate.endpoints.append(endpoint)

        do {
            _ = try candidate.validated()
            try ensureService()
            let credentialID = endpoint.activeAPIKeyID ?? endpoint.id
            if !secret.isEmpty { try tokenStore.setToken(secret, for: credentialID) }
            do {
                try await store.save(candidate)
            } catch {
                if !secret.isEmpty { try? tokenStore.setToken(nil, for: credentialID) }
                throw error
            }
            configuration = candidate
            selectedTunnelID = tunnel.id
            requestedTunnelIDs.insert(tunnel.id)
            lastSavedAt = Date()
            errorMessage = nil
            navigationRequest = .endpoint(endpoint.id)
            await applyRuntimeAvailability()
            await service?.start(tunnel)
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
            try await store.save(candidate)
            configuration = candidate
            lastSavedAt = Date()
            errorMessage = nil
            await inspectEndpoint(endpoint.id)
            await reconcileGateway()
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
            try await store.save(candidate)
            configuration = candidate
            lastSavedAt = Date()
            errorMessage = nil
            try ensureService()
            await reconcileService()
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
            try await store.save(candidate)
            configuration = candidate
            lastSavedAt = Date()
            errorMessage = nil
            await reconcileGateway()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func saveGateway() async -> Bool {
        do {
            try await store.save(configuration)
            lastSavedAt = Date()
            errorMessage = nil
            await reconcileGateway()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeEndpoint(_ endpointID: UUID) async {
        do {
            let result = try await deletionCoordinator.removeEndpoint(endpointID, from: configuration)
            configuration = result.configuration
            inspections[endpointID] = nil
            await reconcileGateway()
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
        subscriptionLoginTask?.cancel()
        subscriptionLoginTask = nil
        cliProxyRestartTask?.cancel()
        cliProxyRestartTask = nil
        cliProxyStabilityTask?.cancel()
        cliProxyStabilityTask = nil
        cliProxyRestartAttempt = 0
        do {
            if !configuration.cliProxy.enabled {
                var candidate = configuration
                candidate.cliProxy.enabled = true
                candidate.reconcileManagedCLIProxyEndpoint()
                let apiKey = try tokenStore.ensureToken(for: candidate.cliProxy.endpointID)
                _ = try tokenStore.ensureCLIProxyManagementPassword()
                try await store.save(candidate)
                configuration = candidate
                tokenAvailability[candidate.cliProxy.endpointID] = !apiKey.isEmpty
                lastSavedAt = Date()
            }

            await reconcileCLIProxy()
            guard case .running = cliProxyState else {
                throw SubscriptionAccountError.proxyUnavailable
            }
            let client = try cliProxyManagementClient()
            let login = try await client.startLogin(provider)
            activeSubscriptionProvider = provider
            activeSubscriptionLogin = login
            errorMessage = nil
            NSWorkspace.shared.open(login.url)
            subscriptionLoginTask = Task { @MainActor [weak self] in
                await self?.pollSubscriptionLogin(state: login.state)
            }
        } catch {
            activeSubscriptionProvider = nil
            activeSubscriptionLogin = nil
            errorMessage = error.localizedDescription
        }
    }

    func cancelSubscriptionLogin() async {
        subscriptionLoginTask?.cancel()
        subscriptionLoginTask = nil
        if let state = activeSubscriptionLogin?.state,
           let client = try? cliProxyManagementClient() {
            try? await client.cancelLogin(state: state)
        }
        activeSubscriptionProvider = nil
        activeSubscriptionLogin = nil
    }

    func refreshSubscriptionAccounts(showErrors: Bool = true) async {
        guard configuration.cliProxy.enabled else {
            subscriptionAccounts = []
            subscriptionUsage = [:]
            return
        }
        isRefreshingSubscriptionAccounts = true
        defer { isRefreshingSubscriptionAccounts = false }
        do {
            let client = try cliProxyManagementClient()
            subscriptionAccounts = try await client.accounts()
            if showErrors { errorMessage = nil }
        } catch {
            if showErrors { errorMessage = error.localizedDescription }
        }
    }

    func refreshSubscriptionAccountState(showErrors: Bool = true) async {
        await refreshSubscriptionAccounts(showErrors: showErrors)
        guard configuration.cliProxy.enabled else { return }
        await inspectEndpoint(configuration.cliProxy.endpointID)
    }

    func refreshSubscriptionUsage() async {
        guard !isRefreshingSubscriptionUsage else { return }
        let codexAccounts = subscriptionAccounts.filter { $0.provider.lowercased() == "codex" }
        guard !codexAccounts.isEmpty, codexBarUsageService.executableURL != nil else {
            subscriptionUsage = [:]
            return
        }
        isRefreshingSubscriptionUsage = true
        defer { isRefreshingSubscriptionUsage = false }
        let snapshots = await codexBarUsageService.usage(for: codexAccounts)
        subscriptionUsage = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
    }

    var isCodexBarAvailable: Bool {
        codexBarUsageService.executableURL != nil
    }

    func removeSubscriptionAccount(_ account: CLIProxyAccount) async {
        do {
            let client = try cliProxyManagementClient()
            try await client.deleteAccount(named: account.name)
            await refreshSubscriptionAccounts()
            await inspectEndpoint(configuration.cliProxy.endpointID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSubscriptionAccountEnabled(_ account: CLIProxyAccount, enabled: Bool) async {
        guard !updatingSubscriptionAccountIDs.contains(account.id) else { return }
        updatingSubscriptionAccountIDs.insert(account.id)
        defer { updatingSubscriptionAccountIDs.remove(account.id) }
        do {
            let client = try cliProxyManagementClient()
            try await client.setAccountDisabled(account, disabled: !enabled)
            await refreshSubscriptionAccounts()
            await inspectEndpoint(configuration.cliProxy.endpointID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copySubscriptionLoginCode() {
        guard let code = activeSubscriptionLogin?.userCode else { return }
        copy(code)
    }

    func copyGatewayToken() {
        guard let key = configuration.gateway.apiKeys.first(where: \.enabled)
                ?? configuration.gateway.apiKeys.first else {
            errorMessage = "No Unified API key is configured."
            return
        }
        copyGatewayAPIKey(key.id)
    }

    func copyGatewayAPIKey(_ keyID: UUID) {
        do {
            copy(try tokenStore.ensureGatewayAPIKey(for: keyID))
            errorMessage = nil
        }
        catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func createGatewayAPIKey(name: String) async -> Bool {
        guard !isUpdatingGatewayAccess else { return false }
        isUpdatingGatewayAccess = true
        defer { isUpdatingGatewayAccess = false }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = GatewayAPIKeyConfiguration(name: cleanName)
        var candidate = configuration
        candidate.gateway.apiKeys.append(key)
        do {
            _ = try candidate.validated()
            let secret = try tokenStore.ensureGatewayAPIKey(for: key.id)
            do {
                try await store.save(candidate)
            } catch {
                try? tokenStore.setGatewayAPIKey(nil, for: key.id)
                throw error
            }
            configuration = candidate
            copy(secret)
            lastSavedAt = Date()
            errorMessage = nil
            await reconcileGateway()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setGatewayRequiresAPIKey(_ required: Bool) async {
        var candidate = configuration
        candidate.gateway.requiresAPIKey = required
        await applyGatewayConfiguration(candidate)
    }

    func setGatewayAPIKeyEnabled(_ keyID: UUID, enabled: Bool) async {
        var candidate = configuration
        guard let index = candidate.gateway.apiKeys.firstIndex(where: { $0.id == keyID }) else { return }
        candidate.gateway.apiKeys[index].enabled = enabled
        await applyGatewayConfiguration(candidate)
    }

    func rotateGatewayAPIKey(_ keyID: UUID) async {
        guard configuration.gateway.apiKeys.contains(where: { $0.id == keyID }) else { return }
        guard !isUpdatingGatewayAccess else { return }
        isUpdatingGatewayAccess = true
        defer { isUpdatingGatewayAccess = false }
        do {
            let replacement = try tokenStore.rotateGatewayAPIKey(for: keyID)
            copy(replacement)
            errorMessage = nil
            await reconcileGateway()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeGatewayAPIKey(_ keyID: UUID) async {
        var candidate = configuration
        guard candidate.gateway.apiKeys.contains(where: { $0.id == keyID }) else { return }
        guard !isUpdatingGatewayAccess else { return }
        isUpdatingGatewayAccess = true
        defer { isUpdatingGatewayAccess = false }
        candidate.gateway.apiKeys.removeAll { $0.id == keyID }
        do {
            try await store.save(candidate)
            configuration = candidate
            lastSavedAt = Date()
            do {
                try tokenStore.setGatewayAPIKey(nil, for: keyID)
                errorMessage = nil
            } catch {
                errorMessage = "The key is no longer accepted, but its unused Keychain value could not be removed: \(error.localizedDescription)"
            }
            await reconcileGateway()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyGatewayConfiguration(_ candidate: ModelMoorConfiguration) async {
        guard !isUpdatingGatewayAccess else { return }
        isUpdatingGatewayAccess = true
        defer { isUpdatingGatewayAccess = false }
        do {
            try await store.save(candidate)
            configuration = candidate
            lastSavedAt = Date()
            errorMessage = nil
            await reconcileGateway()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func hasToken(for endpointID: UUID) -> Bool {
        guard let endpoint = configuration.endpoints.first(where: { $0.id == endpointID }),
              let keyID = endpoint.activeAPIKeyID else { return false }
        return hasToken(forAPIKey: keyID)
    }

    func hasToken(forAPIKey keyID: UUID) -> Bool {
        if let cached = tokenAvailability[keyID] { return cached }
        let available = (try? backgroundTokenStore.token(for: keyID))?.isEmpty == false
        tokenAvailability[keyID] = available
        return available
    }

    func createEndpointAPIKey(
        endpointID: UUID,
        name: String,
        secret: String
    ) async -> Bool {
        guard let index = configuration.endpoints.firstIndex(where: { $0.id == endpointID }) else { return false }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSecret.isEmpty else {
            errorMessage = "Enter an API key."
            return false
        }
        let key = EndpointAPIKeyConfiguration(name: cleanName.isEmpty ? "API key" : cleanName)
        var candidate = configuration
        candidate.endpoints[index].apiKeys.append(key)
        candidate.endpoints[index].activeAPIKeyID = key.id
        do {
            _ = try candidate.validated()
            try tokenStore.setToken(cleanSecret, for: key.id)
            do {
                try await store.save(candidate)
            } catch {
                try? tokenStore.setToken(nil, for: key.id)
                throw error
            }
            configuration = candidate
            tokenAvailability[key.id] = true
            lastSavedAt = Date()
            errorMessage = nil
            if candidate.endpoints[index].enabled { await inspectEndpoint(endpointID) }
            await reconcileGateway()
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
            try tokenStore.setToken(cleanSecret, for: keyID)
            tokenAvailability[keyID] = true
            errorMessage = nil
            if configuration.endpoints.first(where: { $0.id == endpointID })?.activeAPIKeyID == keyID,
               configuration.endpoints.first(where: { $0.id == endpointID })?.enabled == true {
                await inspectEndpoint(endpointID)
                await reconcileGateway()
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func selectEndpointAPIKey(_ keyID: UUID, endpointID: UUID) async {
        guard let index = configuration.endpoints.firstIndex(where: { $0.id == endpointID }),
              configuration.endpoints[index].apiKeys.contains(where: { $0.id == keyID }) else { return }
        var candidate = configuration
        candidate.endpoints[index].activeAPIKeyID = keyID
        do {
            try await store.save(candidate)
            configuration = candidate
            lastSavedAt = Date()
            errorMessage = nil
            if candidate.endpoints[index].enabled { await inspectEndpoint(endpointID) }
            await reconcileGateway()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeEndpointAPIKey(_ keyID: UUID, endpointID: UUID) async {
        guard let index = configuration.endpoints.firstIndex(where: { $0.id == endpointID }),
              configuration.endpoints[index].apiKeys.contains(where: { $0.id == keyID }) else { return }
        var candidate = configuration
        candidate.endpoints[index].apiKeys.removeAll { $0.id == keyID }
        if candidate.endpoints[index].activeAPIKeyID == keyID {
            candidate.endpoints[index].activeAPIKeyID = candidate.endpoints[index].apiKeys.first?.id
        }
        do {
            _ = try candidate.validated()
            let previous = try tokenStore.token(for: keyID)
            try tokenStore.setToken(nil, for: keyID)
            do {
                try await store.save(candidate)
            } catch {
                try? tokenStore.setToken(previous, for: keyID)
                throw error
            }
            configuration = candidate
            tokenAvailability[keyID] = false
            lastSavedAt = Date()
            errorMessage = nil
            if candidate.endpoints[index].enabled { await inspectEndpoint(endpointID) }
            await reconcileGateway()
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
        networkMonitor?.cancel()
        networkMonitor = nil
        inspectionTasks.values.forEach { $0.cancel() }
        inspectionTasks.removeAll()
        subscriptionLoginTask?.cancel()
        subscriptionLoginTask = nil
        cliProxyRestartTask?.cancel()
        cliProxyRestartTask = nil
        cliProxyStabilityTask?.cancel()
        cliProxyStabilityTask = nil
        if let gatewayCoordinator {
            gatewayState = await gatewayCoordinator.reconcile(snapshot: nil)
        } else {
            gatewayState = .stopped
        }
        await cliProxyService?.stop()
        cliProxyService = nil
        cliProxyState = .stopped
        await service?.stopAll()
        service = nil
        runtimeOwnership = nil
    }

    func setUIRefreshActive(_ active: Bool) {
        guard active != isUIRefreshActive else { return }
        isUIRefreshActive = active
        if active {
            usageRefreshTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await self?.refreshTokenUsage()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        } else {
            usageRefreshTask?.cancel()
            usageRefreshTask = nil
        }
    }

    func prepareForSleep() async {
        sleeping = true
        inspectionTasks.values.forEach { $0.cancel() }
        inspectionTasks.removeAll()
        cliProxyRestartTask?.cancel()
        cliProxyRestartTask = nil
        cliProxyStabilityTask?.cancel()
        cliProxyStabilityTask = nil
        if let gatewayCoordinator {
            gatewayState = await gatewayCoordinator.reconcile(snapshot: nil)
        } else {
            gatewayState = .stopped
        }
        await cliProxyService?.stop()
        cliProxyState = .stopped
        await service?.setRuntimeAvailable(false, reason: "Waiting for Mac to wake")
        await diagnosticLog.append(
            subject: .gateway,
            severity: .info,
            category: "sleep",
            summary: "Runtime suspended for system sleep"
        )
    }

    func resumeAfterWake() async {
        sleeping = false
        await applyRuntimeAvailability()
        await reconcileCLIProxy()
        if networkAvailable { await reconcileGateway() }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func dismissError() {
        errorMessage = nil
    }

    func copyDiagnosticSummary() async {
        let value = await diagnosticLog.summary()
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

    private func ensureService() throws {
        guard service == nil else { return }
        let ownership = try RuntimeOwnership.acquire(
            lockFileURL: runtimeProfile.runtimeLockURL,
            owner: "\(runtimeProfile.displayName) app"
        )
        let replacement = TunnelService(
            commandBuilder: SSHCommandBuilder(controlDirectoryURL: runtimeProfile.runtimeDirectoryURL)
        ) { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statuses[status.tunnelID] = status
                await self.diagnosticLog.append(
                    subject: .mooring(status.tunnelID),
                    severity: status.phase == .failed ? .error : (status.failureCategory == nil ? .info : .warning),
                    category: status.failureCategory?.rawValue ?? status.phase.rawValue,
                    summary: status.message
                )
                if status.phase == .connected {
                    await self.inspectEndpoints(forTunnel: status.tunnelID)
                }
                await self.reconcileGateway()
            }
        }
        runtimeOwnership = ownership
        service = replacement
    }

    private func reconcileService() async {
        let desired = configuration.tunnels.filter { requestedTunnelIDs.contains($0.id) }
        await service?.reconcile(desired)
    }

    private func reconcileCLIProxy() async {
        guard configuration.cliProxy.enabled, !sleeping else {
            await cliProxyService?.stop()
            cliProxyState = .stopped
            if !configuration.cliProxy.enabled {
                subscriptionAccounts = []
                subscriptionUsage = [:]
            }
            return
        }
        do {
            let apiKey = try backgroundTokenStore.ensureToken(for: configuration.cliProxy.endpointID)
            let managementPassword = try backgroundTokenStore.ensureCLIProxyManagementPassword()
            if cliProxyService == nil {
                cliProxyService = CLIProxyService(
                    dataDirectoryURL: runtimeProfile.cliProxyDataDirectoryURL
                ) { [weak self] state in
                    Task { @MainActor [weak self] in self?.handleCLIProxyState(state) }
                }
            }
            guard let cliProxyService else { return }
            try await cliProxyService.start(
                configuration: configuration.cliProxy,
                apiKey: apiKey,
                managementPassword: managementPassword
            )
            cliProxyState = await cliProxyService.state
            await refreshSubscriptionAccounts(showErrors: false)
            await inspectEndpoint(configuration.cliProxy.endpointID)
        } catch {
            cliProxyState = .failed(error.localizedDescription)
            await diagnosticLog.append(
                subject: .gateway,
                severity: .error,
                category: "cliproxy.failed",
                summary: error.localizedDescription
            )
        }
    }

    private func handleCLIProxyState(_ state: CLIProxyRuntimeState) {
        cliProxyState = state
        switch state {
        case .running:
            cliProxyRestartTask?.cancel()
            cliProxyRestartTask = nil
            cliProxyStabilityTask?.cancel()
            cliProxyStabilityTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, case .running = self.cliProxyState else { return }
                self.cliProxyRestartAttempt = 0
                self.cliProxyStabilityTask = nil
            }
        case .failed:
            cliProxyStabilityTask?.cancel()
            cliProxyStabilityTask = nil
            guard configuration.cliProxy.enabled,
                  !sleeping,
                  cliProxyRestartAttempt < 5,
                  cliProxyRestartTask == nil else { return }
            let delay = min(30, 1 << cliProxyRestartAttempt)
            cliProxyRestartAttempt += 1
            cliProxyRestartTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.cliProxyRestartTask = nil
                await self.reconcileCLIProxy()
                await self.reconcileGateway()
            }
        case .stopped:
            cliProxyStabilityTask?.cancel()
            cliProxyStabilityTask = nil
        case .starting:
            break
        }
    }

    private func cliProxyManagementClient() throws -> CLIProxyManagementClient {
        guard case .running = cliProxyState else {
            throw SubscriptionAccountError.proxyUnavailable
        }
        guard let password = try backgroundTokenStore.cliProxyManagementPassword(), !password.isEmpty else {
            throw SubscriptionAccountError.managementCredentialUnavailable
        }
        return CLIProxyManagementClient(
            port: configuration.cliProxy.listenPort,
            managementPassword: password
        )
    }

    private func pollSubscriptionLogin(state: String) async {
        do {
            let client = try cliProxyManagementClient()
            for _ in 0..<300 {
                try Task.checkCancellation()
                let status = try await client.loginStatus(state: state)
                switch status.status {
                case "ok":
                    activeSubscriptionLogin = nil
                    activeSubscriptionProvider = nil
                    subscriptionLoginTask = nil
                    await refreshSubscriptionAccounts()
                    await inspectEndpoint(configuration.cliProxy.endpointID)
                    await reconcileGateway()
                    return
                case "error":
                    throw SubscriptionAccountError.loginFailed(status.error ?? "Authentication failed.")
                default:
                    try await Task.sleep(for: .seconds(1))
                }
            }
            throw SubscriptionAccountError.loginTimedOut
        } catch is CancellationError {
            return
        } catch {
            activeSubscriptionLogin = nil
            activeSubscriptionProvider = nil
            subscriptionLoginTask = nil
            errorMessage = error.localizedDescription
        }
    }

    private func networkAvailabilityChanged(_ availability: NetworkAvailability) async {
        networkAvailable = availability == .available
        await applyRuntimeAvailability()
        if networkAvailable, !sleeping {
            await inspectAllEndpoints()
            await reconcileGateway()
        }
    }

    private func applyRuntimeAvailability() async {
        let available = networkAvailable && !sleeping
        let reason = sleeping ? "Waiting for Mac to wake" : "Waiting for network"
        await service?.setRuntimeAvailable(available, reason: reason)
    }

    private func reconcileGateway() async {
        guard configuration.gateway.enabled, !sleeping else {
            if let gatewayCoordinator {
                gatewayState = await gatewayCoordinator.reconcile(snapshot: nil)
            } else {
                gatewayState = .stopped
            }
            return
        }
        do {
            let gatewayAPIKeys = try backgroundTokenStore.enabledGatewayAPIKeys(for: configuration.gateway)
            let secrets = backgroundTokenStore.endpointSecrets(for: configuration)
            let connectedMappings = Set(configuration.tunnels.compactMap { tunnel -> [UUID]? in
                statuses[tunnel.id]?.phase == .connected ? tunnel.enabledMappings.map(\.id) : nil
            }.flatMap { $0 })
            let snapshot = GatewaySnapshot(
                configuration: configuration,
                gatewayAPIKeys: gatewayAPIKeys,
                endpointSecrets: secrets,
                availableMappingIDs: connectedMappings
            )
            gatewayState = await gatewayRuntime().reconcile(snapshot: snapshot)
            switch gatewayState {
            case .running:
                await diagnosticLog.append(
                    subject: .gateway,
                    severity: .info,
                    category: "ready",
                    summary: "Gateway listening on loopback port \(configuration.gateway.listenPort)"
                )
            case let .failed(message):
                errorMessage = message
                await diagnosticLog.append(
                    subject: .gateway,
                    severity: .error,
                    category: "failed",
                    summary: message
                )
            case .stopped:
                break
            }
        } catch {
            gatewayState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            await diagnosticLog.append(
                subject: .gateway,
                severity: .error,
                category: "failed",
                summary: error.localizedDescription
            )
        }
    }

    private func gatewayRuntime() -> GatewayServiceCoordinator {
        if let gatewayCoordinator { return gatewayCoordinator }
        let tokenUsageStore = self.tokenUsageStore
        let diagnosticLog = self.diagnosticLog
        let coordinator = GatewayServiceCoordinator { usage in
            Task {
                do {
                    try await tokenUsageStore.appendUsage(
                        tokens: usage.tokens,
                        routeID: usage.routeID,
                        endpointID: usage.endpointID
                    )
                } catch {
                    await diagnosticLog.append(
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

    func refreshTokenUsage() async {
        do {
            let snapshot = try await tokenUsageStore.snapshot()
            if snapshot != tokenUsage { tokenUsage = snapshot }
        } catch {
            await diagnosticLog.append(
                subject: .gateway,
                severity: .warning,
                category: "usage.read",
                summary: error.localizedDescription
            )
        }
    }

    func tokenUsageReport(
        from startDate: Date,
        to endDate: Date,
        bucketInterval: TimeInterval,
        routeID: UUID?,
        endpointID: UUID?
    ) async -> TokenUsageReport? {
        do {
            return try await tokenUsageStore.report(
                from: startDate,
                to: endDate,
                bucketInterval: bucketInterval,
                routeID: routeID,
                endpointID: endpointID
            )
        } catch {
            await diagnosticLog.append(
                subject: .gateway,
                severity: .warning,
                category: "usage.report",
                summary: error.localizedDescription
            )
            return nil
        }
    }

    private func recordInspection(_ inspection: EndpointInspection, endpointID: UUID) async {
        let isLLMAPI = configuration.endpoints.first(where: { $0.id == endpointID }).map(isRecognizedLLMEndpoint) ?? true
        let severity: DiagnosticSeverity = inspection.errorMessage == nil || !isLLMAPI ? .info : .warning
        let category = inspection.statusCode.map { "http.\($0)" } ?? "inspection"
        let summary = inspection.errorMessage
            ?? inspection.models.map { "Endpoint ready; \($0.count) model(s) discovered" }
            ?? "Endpoint reachable"
        await diagnosticLog.append(
            subject: .endpoint(endpointID),
            severity: severity,
            category: category,
            summary: summary
        )
    }

    private func inspectEndpoints(forTunnel tunnelID: UUID) async {
        guard let tunnel = configuration.tunnels.first(where: { $0.id == tunnelID }) else { return }
        let mappingIDs = Set(tunnel.mappings.map(\.id))
        for endpoint in configuration.endpoints where endpoint.enabled {
            guard case let .sshMapping(mappingID, _) = endpoint.source, mappingIDs.contains(mappingID) else { continue }
            await inspectEndpoint(endpoint.id)
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

    private func uniqueEndpointName(base: String) -> String {
        let names = Set(configuration.endpoints.map { $0.name.lowercased() })
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

private enum SubscriptionAccountError: LocalizedError {
    case proxyUnavailable
    case managementCredentialUnavailable
    case loginFailed(String)
    case loginTimedOut

    var errorDescription: String? {
        switch self {
        case .proxyUnavailable:
            "The managed subscription proxy is not running."
        case .managementCredentialUnavailable:
            "The subscription proxy management credential is unavailable in Keychain."
        case let .loginFailed(message):
            message
        case .loginTimedOut:
            "Account sign-in timed out. Start the sign-in again."
        }
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
