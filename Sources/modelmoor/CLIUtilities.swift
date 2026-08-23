import ArgumentParser
import Foundation
import ModelMoorCore
import ModelMoorSystem

struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum CLISupport {
    /// Configuration path without touching the actor-isolated store.
    static var configurationFilePath: String {
        ModelMoorRuntimeProfile.current.configurationURL.path
    }

    static func store(profile: ModelMoorRuntimeProfile = .current) -> ConfigurationStore {
        ConfigurationStore(
            fileURL: profile.configurationURL,
            legacyImportURL: profile.legacyConfigurationURL,
            initialConfiguration: profile.initialConfiguration
        )
    }

    static func shellQuoted(_ value: String) -> String {
        if value.allSatisfy({ $0.isLetter || $0.isNumber || "-._/:=".contains($0) }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func copyToClipboard(_ value: String) throws {
        do {
            try SystemClipboard.copy(value)
        } catch let error as SystemClipboard.ClipboardError {
            switch error {
            case .unavailable:
                throw CLIError("No clipboard helper is available (pbcopy, wl-copy, xclip or xsel).")
            case .writeFailed:
                throw CLIError("Could not copy the Unified API key to the clipboard.")
            }
        }
    }

    static func singleEndpoint(
        _ name: String?,
        configuration: ModelMoorConfiguration
    ) throws -> APIEndpointConfiguration {
        guard let name else { throw CLIError("An endpoint name is required.") }
        guard let endpoint = configuration.endpoints.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString == name
        }) else { throw CLIError("Endpoint not found: \(name)") }
        return endpoint
    }

    static func mappingIndex(_ configuration: ModelMoorConfiguration) -> [UUID: PortMappingConfiguration] {
        Dictionary(uniqueKeysWithValues: configuration.tunnels.flatMap(\.mappings).map { ($0.id, $0) })
    }

    static func endpointSecret(
        for endpoint: APIEndpointConfiguration,
        secretStore: any ModelMoorSecretStore
    ) -> String? {
        guard let keyID = endpoint.activeAPIKeyID else { return nil }
        return try? secretStore.token(for: keyID)
    }

    static func defaultName(for host: String) -> String {
        host.split(separator: ".").first.map(String.init) ?? "remote"
    }

    static func printEndpointURL(named name: String) async throws {
        let configuration = try await store().load()
        let endpoint = try singleEndpoint(name, configuration: configuration)
        print(try EndpointURLResolver.resolve(endpoint, mappings: mappingIndex(configuration)).absoluteString)
    }

    static func printEndpointModels(named name: String) async throws {
        let configuration = try await store().load()
        let endpoint = try singleEndpoint(name, configuration: configuration)
        let secret = endpointSecret(
            for: endpoint,
            secretStore: try SecretStoreResolver.defaultStore()
        )
        let result = await APIInspector().inspect(
            endpoint,
            mappings: mappingIndex(configuration),
            secret: secret
        )
        guard let models = result.models else { throw CLIError(result.errorMessage ?? "No models returned.") }
        models.forEach { print($0.id) }
    }

    static func printCreated(_ tunnel: TunnelConfiguration, path: String) {
        let first = tunnel.mappings.first
        print("Created \(tunnel.name): \(first?.direction.sshFlag ?? "-") \(first?.forwardingSpecification ?? "-") via ssh:\(tunnel.sshHost)")
        print("Saved to \(path)")
    }
}

/// Shared initial-mapping options for `init` and `add`.
struct TunnelMappingOptions: ParsableArguments {
    @Option(help: "local, remote, dynamic, or reverse-dynamic (default: local)")
    var direction: String = "local"

    @Option(help: "Listening port (default: 18888)")
    var listenPort: Int = 18_888

    @Option(help: "Fixed-forward destination (default: 127.0.0.1)")
    var destinationHost: String = "127.0.0.1"

    @Option(help: "Fixed-forward destination port (default: 8888)")
    var destinationPort: Int = 8_888

    @Option(help: "API inspection path (default: /v1/models)")
    var probePath: String = "/v1/models"

    @Option(help: "Endpoint protocol: http or https (default: http)")
    var scheme: String = "http"

    @Option(help: "Mooring display name")
    var name: String? = nil

    private func validatedPort(_ value: Int, _ option: String) throws -> Int {
        guard (1...65_535).contains(value) else {
            throw CLIError("Invalid --\(option): \(value)")
        }
        return value
    }

    func makeTunnel(name tunnelName: String, sshHost: String) throws -> TunnelConfiguration {
        let direction: PortForwardDirection
        switch self.direction.lowercased() {
        case "local": direction = .local
        case "remote": direction = .remote
        case "dynamic": direction = .dynamic
        case "reverse-dynamic", "reversedynamic": direction = .reverseDynamic
        case let raw: throw CLIError("Invalid --direction: \(raw)")
        }
        let mapping = PortMappingConfiguration(
            name: direction.isDynamic ? "SOCKS Proxy" : "LLM API",
            direction: direction,
            listenPort: try validatedPort(listenPort, "listen-port"),
            destinationHost: destinationHost,
            destinationPort: try validatedPort(destinationPort, "destination-port")
        )
        return try TunnelConfiguration(
            name: tunnelName,
            sshHost: sshHost,
            mappings: [mapping]
        ).validated()
    }

    func makeEndpoint(for tunnel: TunnelConfiguration) throws -> APIEndpointConfiguration? {
        guard let mapping = tunnel.mappings.first, mapping.direction == .local else { return nil }
        let endpointScheme: EndpointScheme
        switch scheme.lowercased() {
        case "http": endpointScheme = .http
        case "https": endpointScheme = .https
        case let raw: throw CLIError("Invalid --scheme: \(raw)")
        }
        let path = probePath
        let isModelList = path.lowercased().hasSuffix("/models")
        return APIEndpointConfiguration(
            id: mapping.id,
            name: "\(tunnel.name) / \(mapping.name)",
            source: .sshMapping(mappingID: mapping.id, originScheme: endpointScheme),
            kind: isModelList ? .openAICompatible : .customHTTP,
            basePath: isModelList ? String(path.dropLast("/models".count)) : "",
            healthPath: path,
            modelListPath: isModelList ? path : nil,
            authentication: .none
        )
    }
}
