import Darwin
import Foundation
import ModelMoorCore
import ModelMoorGateway

@main
struct ModelMoorCLI {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("modelmoor: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        let command = arguments.first ?? "help"
        let parsed = try Arguments(Array(arguments.dropFirst()))
        let store = ConfigurationStore(
            fileURL: ConfigurationStore.defaultURL(),
            legacyImportURL: ConfigurationStore.defaultLegacyImportURL()
        )

        switch command {
        case "help", "--help", "-h":
            print(usage)
        case "config-path":
            print(await store.fileURL.path)
        case "init":
            guard let sshHost = parsed.positionals.first else {
                throw CLIError("Usage: modelmoor init SSH_HOST [options]")
            }
            let existing = try await store.load()
            guard existing.tunnels.isEmpty else {
                throw CLIError("Configuration already contains tunnels. Use `modelmoor add`.")
            }
            let tunnel = try parsed.makeTunnel(
                name: parsed.value("name") ?? defaultName(for: sshHost),
                sshHost: sshHost
            )
            let endpoint = try parsed.makeEndpoint(for: tunnel)
            try await store.save(ModelMoorConfiguration(tunnels: [tunnel], endpoints: endpoint.map { [$0] } ?? []))
            printCreated(tunnel, path: await store.fileURL.path)
        case "add":
            guard parsed.positionals.count == 2 else {
                throw CLIError("Usage: modelmoor add NAME SSH_HOST [options]")
            }
            var configuration = try await store.load()
            let tunnel = try parsed.makeTunnel(
                name: parsed.positionals[0],
                sshHost: parsed.positionals[1]
            )
            let endpoint = try parsed.makeEndpoint(for: tunnel)
            configuration.tunnels.append(tunnel)
            if let endpoint { configuration.endpoints.append(endpoint) }
            try await store.save(configuration)
            printCreated(tunnel, path: await store.fileURL.path)
        case "list":
            let configuration = try await store.load()
            if configuration.tunnels.isEmpty {
                print("No tunnels configured. Run `modelmoor init SSH_HOST`.")
            } else {
                for tunnel in configuration.tunnels {
                    let marker = tunnel.connectOnLaunch ? "●" : "○"
                    print("\(marker) \(tunnel.name)\tssh:\(tunnel.sshHost)\t\(tunnel.enabledMappings.count) forwards")
                    for mapping in tunnel.mappings {
                        let mappingMarker = mapping.enabled ? "  ●" : "  ○"
                        print("\(mappingMarker) \(mapping.name)\t\(mapping.direction.sshFlag) \(mapping.forwardingSpecification)")
                    }
                }
            }
        case "remove":
            guard let name = parsed.positionals.first else { throw CLIError("A tunnel name is required.") }
            let configuration = try await store.load()
            guard let tunnel = configuration.tunnels.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { throw CLIError("Tunnel not found: \(name)") }
            let result = try await ConfigurationDeletionCoordinator(
                store: store,
                secretStore: KeychainTokenStore()
            ).removeTunnel(tunnel.id, from: configuration)
            print("Removed \(name), \(result.removedEndpointIDs.count) endpoint(s), and \(result.removedRouteIDs.count) route(s)")
        case "enable":
            try await mutateNamedTunnel(parsed, store: store) { configuration, index in
                configuration.tunnels[index].connectOnLaunch = true
            }
        case "disable":
            try await mutateNamedTunnel(parsed, store: store) { configuration, index in
                configuration.tunnels[index].connectOnLaunch = false
            }
        case "probe":
            let configuration = try await store.load()
            let endpoints = try selectedEndpoints(parsed.positionals, configuration: configuration)
            let inspector = APIInspector()
            let tokens = KeychainTokenStore()
            let mappings = Dictionary(uniqueKeysWithValues: configuration.tunnels.flatMap(\.mappings).map { ($0.id, $0) })
            var failed = false
            for endpoint in endpoints {
                let secret = endpoint.activeAPIKeyID.flatMap { try? tokens.token(for: $0) }
                let inspection = await inspector.inspect(endpoint, mappings: mappings, secret: secret)
                let state = inspection.isReachable ? "ok" : "down"
                let models = inspection.models.map { "\($0.count) models" } ?? (inspection.errorMessage ?? "no model metadata")
                print("\(state)\t\(endpoint.name)\t\(inspection.url?.absoluteString ?? "-")\t\(models)")
                failed = failed || !inspection.isReachable
            }
            if failed { throw CLIError("One or more APIs are unreachable.") }
        case "endpoint":
            try await runEndpointCommand(parsed, store: store)
        case "url":
            let configuration = try await store.load()
            let endpoint = try singleEndpoint(parsed.positionals.first, configuration: configuration)
            print(try EndpointURLResolver.resolve(endpoint, mappings: mappingIndex(configuration)).absoluteString)
        case "models":
            let configuration = try await store.load()
            let endpoint = try singleEndpoint(parsed.positionals.first, configuration: configuration)
            let inspection = await APIInspector().inspect(
                endpoint,
                mappings: mappingIndex(configuration),
                secret: endpoint.activeAPIKeyID.flatMap { try? KeychainTokenStore().token(for: $0) }
            )
            guard let models = inspection.models else {
                throw CLIError(inspection.errorMessage ?? "Endpoint did not return a model list.")
            }
            models.forEach { print($0.id) }
        case "route":
            let configuration = try await store.load()
            guard parsed.positionals.first == "list" else { throw CLIError("Usage: modelmoor route list") }
            for route in configuration.routes {
                let marker = route.enabled ? "●" : "○"
                let endpoint = configuration.endpoints.first(where: { $0.id == route.endpointID })?.name ?? "missing"
                print("\(marker) \(route.publicModel)\t-> \(endpoint):\(route.upstreamModel)")
            }
        case "gateway":
            let configuration = try await store.load()
            switch parsed.positionals.first ?? "status" {
            case "url": print("http://127.0.0.1:\(configuration.gateway.listenPort)/v1")
            case "status": print(configuration.gateway.enabled ? "enabled\t127.0.0.1:\(configuration.gateway.listenPort)" : "disabled")
            case "token":
                guard parsed.hasFlag("copy") else {
                    throw CLIError("Usage: modelmoor gateway token --copy")
                }
                guard let key = configuration.gateway.apiKeys.first(where: \.enabled)
                        ?? configuration.gateway.apiKeys.first else {
                    throw CLIError("No Unified API key is configured.")
                }
                try copyToPasteboard(KeychainTokenStore().ensureGatewayAPIKey(for: key.id))
                print("Copied the Unified API key to the pasteboard.")
            default: throw CLIError("Usage: modelmoor gateway url|status|token --copy")
            }
        case "ssh-command":
            for tunnel in try await selectedTunnels(parsed, store: store, includeDisabled: true) {
                let builder = SSHCommandBuilder()
                let commands = [
                    ("master", builder.command(for: tunnel)),
                    ("forward", builder.controlCommand(.forward, for: tunnel))
                ]
                for (label, built) in commands {
                    let rendered = ([built.executableURL.path] + built.arguments)
                        .map(shellQuoted)
                        .joined(separator: " ")
                    print("\(label)\t\(rendered)")
                }
            }
        case "run":
            let configuration = try await store.load()
            let tunnels = try await selectedTunnels(
                parsed,
                store: store,
                includeDisabled: !parsed.positionals.isEmpty
            )
            guard !tunnels.isEmpty || configuration.gateway.enabled else {
                throw CLIError("No moorings or Local Gateway are enabled for startup.")
            }
            let ownership = try RuntimeOwnership.acquire(owner: "modelmoor run")
            defer { withExtendedLifetime(ownership) {} }
            let service = TunnelService { status in
                guard let tunnel = tunnels.first(where: { $0.id == status.tunnelID }) else { return }
                print("[\(tunnel.name)] \(status.phase.rawValue): \(status.message)")
            }
            await service.startAll(tunnels)
            var gateway: GatewayService?
            if configuration.gateway.enabled {
                let tokenStore = KeychainTokenStore(userInteraction: .disallow)
                let gatewayAPIKeys = try tokenStore.enabledGatewayAPIKeys(for: configuration.gateway)
                let secrets = tokenStore.endpointSecrets(for: configuration)
                let usageStore = TokenUsageStore()
                let instance = GatewayService { usage in
                    Task {
                        try? await usageStore.appendUsage(
                            tokens: usage.tokens,
                            routeID: usage.routeID,
                            endpointID: usage.endpointID
                        )
                    }
                }
                try await instance.start(snapshot: GatewaySnapshot(
                    configuration: configuration,
                    gatewayAPIKeys: gatewayAPIKeys,
                    endpointSecrets: secrets
                ))
                gateway = instance
                print("Gateway ready at http://127.0.0.1:\(configuration.gateway.listenPort)/v1")
            }
            print("ModelMoor is running. Press Ctrl-C to stop.")
            await TerminationSignal.wait()
            await gateway?.stop()
            await service.stopAll()
        default:
            throw CLIError("Unknown command: \(command)\n\n\(usage)")
        }
    }

    private static func runEndpointCommand(_ arguments: Arguments, store: ConfigurationStore) async throws {
        let configuration = try await store.load()
        let subcommand = arguments.positionals.first ?? "list"
        switch subcommand {
        case "list":
            let mappings = mappingIndex(configuration)
            for endpoint in configuration.endpoints {
                let marker = endpoint.enabled ? "●" : "○"
                let url = (try? EndpointURLResolver.resolve(endpoint, mappings: mappings).absoluteString) ?? "invalid"
                print("\(marker) \(endpoint.name)\t\(endpoint.kind.rawValue)\t\(url)")
            }
        case "url":
            let endpoint = try singleEndpoint(arguments.positionals.dropFirst().first, configuration: configuration)
            print(try EndpointURLResolver.resolve(endpoint, mappings: mappingIndex(configuration)).absoluteString)
        case "models":
            let endpoint = try singleEndpoint(arguments.positionals.dropFirst().first, configuration: configuration)
            let result = await APIInspector().inspect(
                endpoint,
                mappings: mappingIndex(configuration),
                secret: endpoint.activeAPIKeyID.flatMap { try? KeychainTokenStore().token(for: $0) }
            )
            guard let models = result.models else { throw CLIError(result.errorMessage ?? "No models returned.") }
            models.forEach { print($0.id) }
        default:
            throw CLIError("Usage: modelmoor endpoint list|url NAME|models NAME")
        }
    }

    private static func selectedEndpoints(
        _ names: [String],
        configuration: ModelMoorConfiguration
    ) throws -> [APIEndpointConfiguration] {
        guard let name = names.first else { return configuration.endpoints.filter(\.enabled) }
        return [try singleEndpoint(name, configuration: configuration)]
    }

    private static func singleEndpoint(
        _ name: String?,
        configuration: ModelMoorConfiguration
    ) throws -> APIEndpointConfiguration {
        guard let name else { throw CLIError("An endpoint name is required.") }
        guard let endpoint = configuration.endpoints.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString == name
        }) else { throw CLIError("Endpoint not found: \(name)") }
        return endpoint
    }

    private static func mappingIndex(_ configuration: ModelMoorConfiguration) -> [UUID: PortMappingConfiguration] {
        Dictionary(uniqueKeysWithValues: configuration.tunnels.flatMap(\.mappings).map { ($0.id, $0) })
    }

    private static func selectedTunnels(
        _ arguments: Arguments,
        store: ConfigurationStore,
        includeDisabled: Bool
    ) async throws -> [TunnelConfiguration] {
        let configuration = try await store.load()
        let selected: [TunnelConfiguration]
        if let name = arguments.positionals.first {
            selected = configuration.tunnels.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            guard !selected.isEmpty else { throw CLIError("Tunnel not found: \(name)") }
        } else {
            selected = configuration.tunnels
        }
        return includeDisabled ? selected : selected.filter(\.connectOnLaunch)
    }

    private static func mutateNamedTunnel(
        _ arguments: Arguments,
        store: ConfigurationStore,
        mutation: (inout ModelMoorConfiguration, Int) -> Void
    ) async throws {
        guard let name = arguments.positionals.first else {
            throw CLIError("A tunnel name is required.")
        }
        var configuration = try await store.load()
        guard let index = configuration.tunnels.firstIndex(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw CLIError("Tunnel not found: \(name)")
        }
        mutation(&configuration, index)
        try await store.save(configuration)
        print("Updated \(name)")
    }

    private static func defaultName(for host: String) -> String {
        host.split(separator: ".").first.map(String.init) ?? "remote"
    }

    private static func printCreated(_ tunnel: TunnelConfiguration, path: String) {
        let first = tunnel.mappings.first
        print("Created \(tunnel.name): \(first?.direction.sshFlag ?? "-") \(first?.forwardingSpecification ?? "-") via ssh:\(tunnel.sshHost)")
        print("Saved to \(path)")
    }

    private static func shellQuoted(_ value: String) -> String {
        if value.allSatisfy({ $0.isLetter || $0.isNumber || "-._/:=".contains($0) }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func copyToPasteboard(_ value: String) throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(value.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError("Could not copy the Unified API key to the pasteboard.")
        }
    }

    private static let usage = """
    ModelMoor: remote and commercial models, one local API.

    Usage:
      modelmoor init SSH_HOST [--name NAME] [options]
      modelmoor add NAME SSH_HOST [options]
      modelmoor list
      modelmoor run [NAME]
      modelmoor probe [NAME]
      modelmoor endpoint list|url NAME|models NAME
      modelmoor url ENDPOINT
      modelmoor models ENDPOINT
      modelmoor route list
      modelmoor gateway url|status|token --copy
      modelmoor ssh-command [NAME]
      modelmoor enable NAME
      modelmoor disable NAME
      modelmoor remove NAME
      modelmoor config-path

    Initial mapping options:
      --direction TYPE            local, remote, dynamic, or reverse-dynamic (default: local)
      --listen-port PORT          Listening port (default: 18888)
      --destination-host HOST     Fixed-forward destination (default: 127.0.0.1)
      --destination-port PORT     Fixed-forward destination port (default: 8888)
      --probe-path PATH           API inspection path (default: /v1/models)
      --scheme http|https         Endpoint protocol (default: http)
    """
}
private struct Arguments {
    let positionals: [String]
    private let options: [String: String]
    private let flags: Set<String>

    init(_ values: [String]) throws {
        var positionals: [String] = []
        var options: [String: String] = [:]
        var flags = Set<String>()
        var index = 0
        while index < values.count {
            let value = values[index]
            if value.hasPrefix("--") {
                let key = String(value.dropFirst(2))
                if key == "copy" {
                    flags.insert(key)
                    index += 1
                    continue
                }
                guard index + 1 < values.count, !values[index + 1].hasPrefix("--") else {
                    throw CLIError("Missing value for --\(key)")
                }
                options[key] = values[index + 1]
                index += 2
            } else {
                positionals.append(value)
                index += 1
            }
        }
        self.positionals = positionals
        self.options = options
        self.flags = flags
    }

    func value(_ name: String) -> String? {
        options[name]
    }

    func hasFlag(_ name: String) -> Bool { flags.contains(name) }

    func makeTunnel(name: String, sshHost: String) throws -> TunnelConfiguration {
        let direction: PortForwardDirection
        switch value("direction") ?? "local" {
        case "local": direction = .local
        case "remote": direction = .remote
        case "dynamic": direction = .dynamic
        case "reverse-dynamic", "reverseDynamic": direction = .reverseDynamic
        case let raw: throw CLIError("Invalid --direction: \(raw)")
        }
        let mapping = PortMappingConfiguration(
            name: direction.isDynamic ? "SOCKS Proxy" : "LLM API",
            direction: direction,
            listenPort: try port("listen-port", default: 18_888),
            destinationHost: value("destination-host") ?? "127.0.0.1",
            destinationPort: try port("destination-port", default: 8_888)
        )
        return try TunnelConfiguration(
            name: name,
            sshHost: sshHost,
            mappings: [mapping]
        ).validated()
    }

    func makeEndpoint(for tunnel: TunnelConfiguration) throws -> APIEndpointConfiguration? {
        guard let mapping = tunnel.mappings.first, mapping.direction == .local else { return nil }
        let scheme: EndpointScheme
        switch value("scheme") ?? "http" {
        case "http": scheme = .http
        case "https": scheme = .https
        case let raw: throw CLIError("Invalid --scheme: \(raw)")
        }
        let probePath = value("probe-path") ?? "/v1/models"
        let isModelList = probePath.lowercased().hasSuffix("/models")
        return APIEndpointConfiguration(
            id: mapping.id,
            name: "\(tunnel.name) / \(mapping.name)",
            source: .sshMapping(mappingID: mapping.id, originScheme: scheme),
            kind: isModelList ? .openAICompatible : .customHTTP,
            basePath: isModelList ? String(probePath.dropLast("/models".count)) : "",
            healthPath: probePath,
            modelListPath: isModelList ? probePath : nil,
            authentication: .none
        )
    }

    private func port(_ name: String, default defaultValue: Int) throws -> Int {
        guard let raw = value(name) else { return defaultValue }
        guard let port = Int(raw), (1...65_535).contains(port) else {
            throw CLIError("Invalid --\(name): \(raw)")
        }
        return port
    }
}

private struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private enum TerminationSignal {
    static func wait() async {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        await withCheckedContinuation { continuation in
            let latch = SignalLatch(continuation)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT)
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM)
            interrupt.setEventHandler { latch.resume() }
            terminate.setEventHandler { latch.resume() }
            latch.sources = [interrupt, terminate]
            interrupt.resume()
            terminate.resume()
        }
    }
}

private final class SignalLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    var sources: [DispatchSourceSignal] = []

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.withLock {
            guard let continuation else { return }
            self.continuation = nil
            sources.forEach { $0.cancel() }
            self.sources.removeAll()
            continuation.resume()
        }
    }
}
