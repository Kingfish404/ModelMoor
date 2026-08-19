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

public actor ConfigurationDeletionCoordinator {
    private let store: ConfigurationStore
    private let secretStore: any EndpointSecretStore

    public init(store: ConfigurationStore, secretStore: any EndpointSecretStore) {
        self.store = store
        self.secretStore = secretStore
    }

    public func removeTunnel(
        _ tunnelID: UUID,
        from configuration: ModelMoorConfiguration
    ) async throws -> ConfigurationCascadeResult {
        try await commit(
            ConfigurationCascade.removingTunnel(tunnelID, from: configuration),
            removingSecretsFrom: configuration
        )
    }

    public func removeMapping(
        _ mappingID: UUID,
        fromTunnel tunnelID: UUID,
        in configuration: ModelMoorConfiguration
    ) async throws -> ConfigurationCascadeResult {
        try await commit(
            ConfigurationCascade.removingMapping(mappingID, fromTunnel: tunnelID, in: configuration),
            removingSecretsFrom: configuration
        )
    }

    public func removeEndpoint(
        _ endpointID: UUID,
        from configuration: ModelMoorConfiguration
    ) async throws -> ConfigurationCascadeResult {
        try await commit(
            ConfigurationCascade.removingEndpoint(endpointID, from: configuration),
            removingSecretsFrom: configuration
        )
    }

    public func addEndpoint(
        _ endpoint: APIEndpointConfiguration,
        secret: String?,
        to configuration: ModelMoorConfiguration
    ) async throws -> ModelMoorConfiguration {
        guard !configuration.endpoints.contains(where: { $0.id == endpoint.id }) else {
            throw ConfigurationError.invalidValue("Endpoint already exists: \(endpoint.id.uuidString)")
        }
        var result = configuration
        result.endpoints.append(endpoint)
        _ = try result.validated()

        let credentialID = endpoint.activeAPIKeyID ?? endpoint.id
        let previousSecret = try secretStore.token(for: credentialID)
        do {
            try secretStore.setToken(secret, for: credentialID)
            try await store.save(result)
            return result
        } catch {
            do {
                try secretStore.setToken(previousSecret, for: credentialID)
            } catch let rollbackError {
                throw ConfigurationDeletionError.rollbackFailed(
                    operation: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }
    }

    private func commit(
        _ result: ConfigurationCascadeResult,
        removingSecretsFrom source: ModelMoorConfiguration
    ) async throws -> ConfigurationCascadeResult {
        let credentialIDs = source.endpoints
            .filter { result.removedEndpointIDs.contains($0.id) }
            .flatMap { endpoint in
                endpoint.apiKeys.isEmpty ? [endpoint.id] : endpoint.apiKeys.map(\.id)
            }
        let savedSecrets = try Dictionary(uniqueKeysWithValues: credentialIDs.map {
            ($0, try secretStore.token(for: $0))
        })
        var deleted: [UUID] = []
        do {
            for credentialID in credentialIDs {
                try secretStore.setToken(nil, for: credentialID)
                deleted.append(credentialID)
            }
            try await store.save(result.configuration)
            return result
        } catch {
            var restorationError: Error?
            for endpointID in deleted {
                do { try secretStore.setToken(savedSecrets[endpointID] ?? nil, for: endpointID) }
                catch { restorationError = restorationError ?? error }
            }
            if let restorationError {
                throw ConfigurationDeletionError.rollbackFailed(
                    operation: error.localizedDescription,
                    rollback: restorationError.localizedDescription
                )
            }
            throw error
        }
    }
}

public enum ConfigurationDeletionError: LocalizedError, Equatable {
    case rollbackFailed(operation: String, rollback: String)

    public var errorDescription: String? {
        switch self {
        case let .rollbackFailed(operation, rollback):
            "Deletion failed (\(operation)) and credential rollback also failed (\(rollback))."
        }
    }
}
