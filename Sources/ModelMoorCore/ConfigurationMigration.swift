import Foundation

public enum ConfigurationMigration {
    public static func migrateV2(_ data: Data) throws -> ModelMoorConfiguration {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConfigurationError.unreadable("Could not decode schema 2 configuration: \(error.localizedDescription)")
        }
        guard var dictionary = object as? [String: Any], dictionary["schemaVersion"] as? Int == 2 else {
            throw ConfigurationError.unsupportedSchema((object as? [String: Any])?["schemaVersion"] as? Int ?? -1)
        }
        dictionary["schemaVersion"] = ModelMoorConfiguration.currentSchemaVersion
        do {
            let migratedData = try JSONSerialization.data(withJSONObject: dictionary)
            return try JSONDecoder().decode(ModelMoorConfiguration.self, from: migratedData).validated()
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.unreadable("Could not migrate schema 2 configuration: \(error.localizedDescription)")
        }
    }

    public static func migrateV1(
        _ data: Data,
        endpointHasCredential: (UUID) -> Bool = { _ in false }
    ) throws -> ModelMoorConfiguration {
        let legacy: LegacyConfiguration
        do {
            legacy = try JSONDecoder().decode(LegacyConfiguration.self, from: data)
        } catch {
            throw ConfigurationError.unreadable("Could not decode schema 1 configuration: \(error.localizedDescription)")
        }
        guard legacy.schemaVersion == 1 else {
            throw ConfigurationError.unsupportedSchema(legacy.schemaVersion)
        }

        var endpoints: [APIEndpointConfiguration] = []
        let tunnels = legacy.tunnels.map { tunnel in
            let mappings = tunnel.mappings.map { mapping -> PortMappingConfiguration in
                let migrated = PortMappingConfiguration(
                    id: mapping.id,
                    name: mapping.name,
                    direction: mapping.direction,
                    listenHost: mapping.listenHost,
                    listenPort: mapping.listenPort,
                    destinationHost: mapping.destinationHost,
                    destinationPort: mapping.destinationPort,
                    enabled: mapping.enabled
                )
                if mapping.direction == .local,
                   !mapping.probePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let path = mapping.probePath.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isModelList = path.lowercased().hasSuffix("/models")
                    endpoints.append(APIEndpointConfiguration(
                        id: mapping.id,
                        name: "\(tunnel.name) / \(mapping.name)",
                        source: .sshMapping(mappingID: mapping.id, originScheme: mapping.scheme),
                        kind: isModelList ? .openAICompatible : .customHTTP,
                        basePath: isModelList ? String(path.dropLast("/models".count)) : "",
                        healthPath: path,
                        modelListPath: isModelList ? path : nil,
                        pollIntervalSeconds: 30,
                        authentication: endpointHasCredential(mapping.id) ? .bearer : .none,
                        enabled: mapping.enabled
                    ))
                }
                return migrated
            }
            return TunnelConfiguration(
                id: tunnel.id,
                name: tunnel.name,
                sshHost: tunnel.sshHost,
                mappings: mappings,
                connectOnLaunch: tunnel.enabled,
                autoReconnect: tunnel.autoReconnect,
                reconnectInitialDelaySeconds: tunnel.reconnectInitialDelaySeconds,
                reconnectMaximumDelaySeconds: tunnel.reconnectMaximumDelaySeconds,
                connectTimeoutSeconds: tunnel.connectTimeoutSeconds,
                keepAliveIntervalSeconds: tunnel.keepAliveIntervalSeconds,
                keepAliveFailureCount: tunnel.keepAliveFailureCount
            )
        }
        let migrated = ModelMoorConfiguration(
            tunnels: tunnels,
            endpoints: endpoints,
            hasPreparedRecommendedEndpoints: false
        )
        return try migrated.validated()
    }
}

private struct LegacyConfiguration: Decodable {
    let schemaVersion: Int
    let tunnels: [LegacyTunnel]
}

private struct LegacyTunnel: Decodable {
    let id: UUID
    let name: String
    let sshHost: String
    let mappings: [LegacyMapping]
    let enabled: Bool
    let autoReconnect: Bool
    let reconnectInitialDelaySeconds: Int
    let reconnectMaximumDelaySeconds: Int
    let connectTimeoutSeconds: Int
    let keepAliveIntervalSeconds: Int
    let keepAliveFailureCount: Int
}

private struct LegacyMapping: Decodable {
    let id: UUID
    let name: String
    let direction: PortForwardDirection
    let listenHost: String
    let listenPort: Int
    let destinationHost: String
    let destinationPort: Int
    let scheme: EndpointScheme
    let probePath: String
    let enabled: Bool
}
