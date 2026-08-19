import Foundation

public enum PortForwardDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case local
    case remote
    case dynamic
    case reverseDynamic

    public var sshFlag: String {
        switch self {
        case .local: "-L"
        case .remote, .reverseDynamic: "-R"
        case .dynamic: "-D"
        }
    }

    public var isDynamic: Bool {
        self == .dynamic || self == .reverseDynamic
    }

    public var listensLocally: Bool {
        self == .local || self == .dynamic
    }
}

public enum EndpointScheme: String, Codable, CaseIterable, Equatable, Sendable {
    case http
    case https
}

public struct PortMappingConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var direction: PortForwardDirection
    public var listenHost: String
    public var listenPort: Int
    public var destinationHost: String
    public var destinationPort: Int
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String = "LLM API",
        direction: PortForwardDirection = .local,
        listenHost: String = "127.0.0.1",
        listenPort: Int = 18_888,
        destinationHost: String = "127.0.0.1",
        destinationPort: Int = 8_888,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.direction = direction
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
        self.enabled = enabled
    }

    public var forwardingSpecification: String {
        if direction.isDynamic {
            return "\(listenHost):\(listenPort)"
        }
        return "\(listenHost):\(listenPort):\(destinationHost):\(destinationPort)"
    }

    public func validated() throws -> PortMappingConfiguration {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidValue("Mapping name cannot be empty.")
        }
        guard listenHost == "127.0.0.1" || listenHost == "localhost" else {
            let side = direction.listensLocally ? "Local" : "Remote"
            throw ConfigurationError.invalidValue("\(side) listen address must be loopback.")
        }
        guard (1...65_535).contains(listenPort) else {
            throw ConfigurationError.invalidValue("Listen port must be between 1 and 65535.")
        }
        if !direction.isDynamic {
            guard (1...65_535).contains(destinationPort) else {
                throw ConfigurationError.invalidValue("Destination port must be between 1 and 65535.")
            }
            guard Self.isSafeHost(destinationHost) else {
                throw ConfigurationError.invalidValue("Destination must be a hostname or IPv4 address.")
            }
        }
        return self
    }

    private static func isSafeHost(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !trimmed.contains(where: { $0.isWhitespace })
            && !trimmed.contains(":")
            && !trimmed.hasPrefix("-")
    }
}

public struct TunnelConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var sshHost: String
    public var mappings: [PortMappingConfiguration]
    public var connectOnLaunch: Bool
    public var autoReconnect: Bool
    public var reconnectInitialDelaySeconds: Int
    public var reconnectMaximumDelaySeconds: Int
    public var connectTimeoutSeconds: Int
    public var keepAliveIntervalSeconds: Int
    public var keepAliveFailureCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        sshHost: String,
        mappings: [PortMappingConfiguration] = [PortMappingConfiguration()],
        connectOnLaunch: Bool = true,
        autoReconnect: Bool = true,
        reconnectInitialDelaySeconds: Int = 1,
        reconnectMaximumDelaySeconds: Int = 30,
        connectTimeoutSeconds: Int = 10,
        keepAliveIntervalSeconds: Int = 15,
        keepAliveFailureCount: Int = 3
    ) {
        self.id = id
        self.name = name
        self.sshHost = sshHost
        self.mappings = mappings
        self.connectOnLaunch = connectOnLaunch
        self.autoReconnect = autoReconnect
        self.reconnectInitialDelaySeconds = reconnectInitialDelaySeconds
        self.reconnectMaximumDelaySeconds = reconnectMaximumDelaySeconds
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.keepAliveIntervalSeconds = keepAliveIntervalSeconds
        self.keepAliveFailureCount = keepAliveFailureCount
    }

    public var enabledMappings: [PortMappingConfiguration] { mappings.filter(\.enabled) }

    public func validated() throws -> TunnelConfiguration {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidValue("Mooring name cannot be empty.")
        }
        guard !sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidValue("SSH target cannot be empty.")
        }
        guard !sshHost.contains(where: { $0.isWhitespace }), !sshHost.hasPrefix("-") else {
            throw ConfigurationError.invalidValue("SSH target is not safe.")
        }
        guard !mappings.isEmpty else {
            throw ConfigurationError.invalidValue("A mooring needs at least one port mapping.")
        }
        _ = try mappings.map { try $0.validated() }
        guard !connectOnLaunch || !enabledMappings.isEmpty else {
            throw ConfigurationError.invalidValue("A mooring that connects on launch needs an enabled port mapping.")
        }
        if let duplicateName = Dictionary(grouping: mappings, by: { $0.name.lowercased() })
            .first(where: { $0.value.count > 1 })?.key {
            throw ConfigurationError.invalidValue("Duplicate mapping name: \(duplicateName)")
        }
        guard (1...120).contains(connectTimeoutSeconds) else {
            throw ConfigurationError.invalidValue("Connect timeout must be between 1 and 120 seconds.")
        }
        guard (5...3_600).contains(keepAliveIntervalSeconds) else {
            throw ConfigurationError.invalidValue("Keepalive interval must be between 5 and 3600 seconds.")
        }
        guard (1...20).contains(keepAliveFailureCount) else {
            throw ConfigurationError.invalidValue("Keepalive failure count must be between 1 and 20.")
        }
        guard (1...60).contains(reconnectInitialDelaySeconds),
              reconnectInitialDelaySeconds <= reconnectMaximumDelaySeconds,
              reconnectMaximumDelaySeconds <= 3_600 else {
            throw ConfigurationError.invalidValue("Reconnect delays must be ordered between 1 and 3600 seconds.")
        }
        return self
    }
}

public struct ModelMoorConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public var schemaVersion: Int
    public var tunnels: [TunnelConfiguration]
    public var endpoints: [APIEndpointConfiguration]
    public var routes: [ModelRouteConfiguration]
    public var gateway: GatewayConfiguration
    public var hasPreparedRecommendedEndpoints: Bool

    public init(
        schemaVersion: Int = currentSchemaVersion,
        tunnels: [TunnelConfiguration] = [],
        endpoints: [APIEndpointConfiguration] = [],
        routes: [ModelRouteConfiguration] = [],
        gateway: GatewayConfiguration = GatewayConfiguration(),
        hasPreparedRecommendedEndpoints: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.tunnels = tunnels
        self.endpoints = endpoints
        self.routes = routes
        self.gateway = gateway
        self.hasPreparedRecommendedEndpoints = hasPreparedRecommendedEndpoints
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, tunnels, endpoints, routes, gateway, hasPreparedRecommendedEndpoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        tunnels = try container.decodeIfPresent([TunnelConfiguration].self, forKey: .tunnels) ?? []
        endpoints = try container.decodeIfPresent([APIEndpointConfiguration].self, forKey: .endpoints) ?? []
        routes = try container.decodeIfPresent([ModelRouteConfiguration].self, forKey: .routes) ?? []
        gateway = try container.decodeIfPresent(GatewayConfiguration.self, forKey: .gateway) ?? GatewayConfiguration()
        hasPreparedRecommendedEndpoints = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasPreparedRecommendedEndpoints
        ) ?? false
    }

    public func validated() throws -> ModelMoorConfiguration {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ConfigurationError.unsupportedSchema(schemaVersion)
        }
        _ = try tunnels.map { try $0.validated() }
        if let duplicateName = Dictionary(grouping: tunnels, by: { $0.name.lowercased() })
            .first(where: { $0.value.count > 1 })?.key {
            throw ConfigurationError.invalidValue("Duplicate mooring name: \(duplicateName)")
        }

        var localListeners = Set<String>()
        var remoteListeners = Set<String>()
        for tunnel in tunnels {
            for mapping in tunnel.enabledMappings {
                if mapping.direction.listensLocally {
                    let key = "\(mapping.listenHost.lowercased()):\(mapping.listenPort)"
                    guard localListeners.insert(key).inserted else {
                        throw ConfigurationError.invalidValue("Local listener \(key) is used more than once.")
                    }
                } else {
                    let key = "\(tunnel.sshHost.lowercased())|\(mapping.listenHost.lowercased()):\(mapping.listenPort)"
                    guard remoteListeners.insert(key).inserted else {
                        throw ConfigurationError.invalidValue("Remote listener \(mapping.listenHost):\(mapping.listenPort) is used more than once for \(tunnel.sshHost).")
                    }
                }
            }
        }
        let mappings = tunnels.flatMap(\.mappings)
        let mappingIDs = Set(mappings.map(\.id))
        _ = try endpoints.map { try $0.validated(mappingIDs: mappingIDs) }
        if let duplicateEndpointName = Dictionary(grouping: endpoints, by: { $0.name.lowercased() })
            .first(where: { $0.value.count > 1 })?.key {
            throw ConfigurationError.invalidValue("Duplicate endpoint name: \(duplicateEndpointName)")
        }
        let endpointByID = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.id, $0) })
        var publicModels = Set<String>()
        for route in routes {
            let publicModel = route.publicModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let upstreamModel = route.upstreamModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !publicModel.isEmpty, !upstreamModel.isEmpty else {
                throw ConfigurationError.invalidValue("Route model names cannot be empty.")
            }
            guard let endpoint = endpointByID[route.endpointID] else {
                throw ConfigurationError.invalidValue("Route \(publicModel) refers to a missing endpoint.")
            }
            guard endpoint.kind == .openAICompatible else {
                throw ConfigurationError.invalidValue("Route \(publicModel) must use an OpenAI-compatible endpoint.")
            }
            if route.enabled {
                guard endpoint.enabled else {
                    throw ConfigurationError.invalidValue("Enabled route \(publicModel) refers to a disabled endpoint.")
                }
                guard publicModels.insert(publicModel).inserted else {
                    throw ConfigurationError.invalidValue("Duplicate public model: \(publicModel)")
                }
            }
        }
        _ = try gateway.validated()
        return self
    }
}

public enum ConfigurationError: LocalizedError, Equatable {
    case invalidValue(String)
    case unreadable(String)
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidValue(message), let .unreadable(message): message
        case let .unsupportedSchema(version):
            "Unsupported configuration schema \(version). This version of ModelMoor supports schema \(ModelMoorConfiguration.currentSchemaVersion); update ModelMoor before editing this file."
        }
    }
}
