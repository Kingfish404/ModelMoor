import Foundation
import ModelMoorCore

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
