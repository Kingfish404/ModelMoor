import Foundation

public struct ConfigurationCascadeResult: Equatable, Sendable {
    public var configuration: ModelMoorConfiguration
    public var removedTunnelIDs: Set<UUID>
    public var removedMappingIDs: Set<UUID>
    public var removedEndpointIDs: Set<UUID>
    public var removedRouteIDs: Set<UUID>

    public init(
        configuration: ModelMoorConfiguration,
        removedTunnelIDs: Set<UUID> = [],
        removedMappingIDs: Set<UUID> = [],
        removedEndpointIDs: Set<UUID> = [],
        removedRouteIDs: Set<UUID> = []
    ) {
        self.configuration = configuration
        self.removedTunnelIDs = removedTunnelIDs
        self.removedMappingIDs = removedMappingIDs
        self.removedEndpointIDs = removedEndpointIDs
        self.removedRouteIDs = removedRouteIDs
    }
}

public enum ConfigurationCascade {
    public static func removingTunnel(
        _ tunnelID: UUID,
        from source: ModelMoorConfiguration
    ) throws -> ConfigurationCascadeResult {
        guard let tunnel = source.tunnels.first(where: { $0.id == tunnelID }) else {
            throw ConfigurationError.invalidValue("Mooring not found: \(tunnelID.uuidString)")
        }
        var result = source
        let mappingIDs = Set(tunnel.mappings.map(\.id))
        result.tunnels.removeAll { $0.id == tunnelID }
        return try removingReferences(
            toMappingIDs: mappingIDs,
            from: result,
            removedTunnelIDs: [tunnelID]
        )
    }

    public static func removingMapping(
        _ mappingID: UUID,
        fromTunnel tunnelID: UUID,
        in source: ModelMoorConfiguration
    ) throws -> ConfigurationCascadeResult {
        guard let tunnelIndex = source.tunnels.firstIndex(where: { $0.id == tunnelID }),
              source.tunnels[tunnelIndex].mappings.contains(where: { $0.id == mappingID }) else {
            throw ConfigurationError.invalidValue("Port mapping not found: \(mappingID.uuidString)")
        }
        var result = source
        result.tunnels[tunnelIndex].mappings.removeAll { $0.id == mappingID }
        return try removingReferences(toMappingIDs: [mappingID], from: result)
    }

    public static func removingEndpoint(
        _ endpointID: UUID,
        from source: ModelMoorConfiguration
    ) throws -> ConfigurationCascadeResult {
        guard source.endpoints.contains(where: { $0.id == endpointID }) else {
            throw ConfigurationError.invalidValue("Endpoint not found: \(endpointID.uuidString)")
        }
        var result = source
        result.endpoints.removeAll { $0.id == endpointID }
        let routeIDs = Set(result.routes.filter { $0.endpointID == endpointID }.map(\.id))
        result.routes.removeAll { routeIDs.contains($0.id) }
        _ = try result.validated()
        return ConfigurationCascadeResult(
            configuration: result,
            removedEndpointIDs: [endpointID],
            removedRouteIDs: routeIDs
        )
    }

    private static func removingReferences(
        toMappingIDs mappingIDs: Set<UUID>,
        from source: ModelMoorConfiguration,
        removedTunnelIDs: Set<UUID> = []
    ) throws -> ConfigurationCascadeResult {
        var result = source
        let endpointIDs = Set(result.endpoints.compactMap { endpoint -> UUID? in
            guard case let .sshMapping(mappingID, _) = endpoint.source,
                  mappingIDs.contains(mappingID) else { return nil }
            return endpoint.id
        })
        result.endpoints.removeAll { endpointIDs.contains($0.id) }
        let routeIDs = Set(result.routes.filter { endpointIDs.contains($0.endpointID) }.map(\.id))
        result.routes.removeAll { routeIDs.contains($0.id) }
        _ = try result.validated()
        return ConfigurationCascadeResult(
            configuration: result,
            removedTunnelIDs: removedTunnelIDs,
            removedMappingIDs: mappingIDs,
            removedEndpointIDs: endpointIDs,
            removedRouteIDs: routeIDs
        )
    }
}

public protocol EndpointSecretStore: Sendable {
    func token(for endpointID: UUID) throws -> String?
    func setToken(_ token: String?, for endpointID: UUID) throws
}
