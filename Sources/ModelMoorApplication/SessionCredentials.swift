import Foundation
import ModelMoorCore

/// Credential-related session commands shared by GUI and (later) other
/// presentation layers. Secrets flow through the platform secret store only;
/// generated secrets are RETURNED to the caller exactly once (the GUI copies
/// them to the pasteboard) and never enter snapshots, logs or diagnostics.
extension ModelMoorSession {
    // MARK: - Unified API keys

    /// Adds a gateway API key, generates its secret, persists, and returns the
    /// secret for one-time display. Rolls back the secret when saving fails.
    @discardableResult
    public func createGatewayAPIKey(name: String) async throws -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = GatewayAPIKeyConfiguration(name: cleanName)
        var candidate = snapshot.configuration
        candidate.gateway.apiKeys.append(key)
        _ = try candidate.validated()
        let secret = try secretStore().ensureGatewayAPIKey(for: key.id)
        do {
            try await saveConfiguration(candidate)
        } catch {
            try? secretStore().setGatewayAPIKey(nil, for: key.id)
            throw error
        }
        return secret
    }

    public func setGatewayRequiresAPIKey(_ required: Bool) async throws {
        var candidate = snapshot.configuration
        candidate.gateway.requiresAPIKey = required
        try await saveConfiguration(candidate)
    }

    public func setGatewayAPIKeyEnabled(_ keyID: UUID, enabled: Bool) async throws {
        var candidate = snapshot.configuration
        guard let index = candidate.gateway.apiKeys.firstIndex(where: { $0.id == keyID }) else { return }
        candidate.gateway.apiKeys[index].enabled = enabled
        try await saveConfiguration(candidate)
    }

    /// Rotates the key's secret and returns the new value for one-time
    /// display. The listener picks up the new value on the next reconcile.
    @discardableResult
    public func rotateGatewayAPIKey(_ keyID: UUID) async throws -> String {
        guard snapshot.configuration.gateway.apiKeys.contains(where: { $0.id == keyID }) else {
            throw ConfigurationError.invalidValue("Unified API key not found: \(keyID.uuidString)")
        }
        let replacement = try secretStore().rotateGatewayAPIKey(for: keyID)
        await reconcileGatewayAfterCredentialChange()
        return replacement
    }

    /// Removes the key from the configuration first (so it stops being
    /// accepted), then best-effort deletes the stored secret.
    public func removeGatewayAPIKey(_ keyID: UUID) async throws {
        var candidate = snapshot.configuration
        guard candidate.gateway.apiKeys.contains(where: { $0.id == keyID }) else { return }
        candidate.gateway.apiKeys.removeAll { $0.id == keyID }
        try await saveConfiguration(candidate)
        try? secretStore().setGatewayAPIKey(nil, for: keyID)
    }

    /// Returns one configured Unified API key for an explicit one-time
    /// presentation action (for example, copying it). The secret is never
    /// published through `AppSnapshot`.
    public func revealGatewayAPIKey(_ keyID: UUID) throws -> String {
        guard snapshot.configuration.gateway.apiKeys.contains(where: { $0.id == keyID }) else {
            throw ConfigurationError.invalidValue("Unified API key not found: \(keyID.uuidString)")
        }
        return try secretStore().ensureGatewayAPIKey(for: keyID)
    }

    // MARK: - Endpoint API keys

    /// Adds an endpoint API key, stores its secret, makes it active, persists,
    /// and returns the key id. Rolls the secret back when saving fails.
    @discardableResult
    public func createEndpointAPIKey(
        endpointID: UUID,
        name: String,
        secret: String
    ) async throws -> UUID {
        guard let index = snapshot.configuration.endpoints.firstIndex(where: { $0.id == endpointID }) else {
            throw SessionError.endpointNotFound(endpointID)
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSecret.isEmpty else {
            throw ConfigurationError.invalidValue("Enter an API key.")
        }
        let key = EndpointAPIKeyConfiguration(name: cleanName.isEmpty ? "API key" : cleanName)
        var candidate = snapshot.configuration
        candidate.endpoints[index].apiKeys.append(key)
        candidate.endpoints[index].activeAPIKeyID = key.id
        _ = try candidate.validated()
        try secretStore().setToken(cleanSecret, for: key.id)
        do {
            try await saveConfiguration(candidate)
        } catch {
            try? secretStore().setToken(nil, for: key.id)
            throw error
        }
        if candidate.endpoints[index].enabled { await inspectEndpoint(endpointID) }
        setEndpointCredentialAvailable(true, keyID: key.id)
        return key.id
    }

    public func replaceEndpointAPIKey(_ keyID: UUID, endpointID: UUID, secret: String) async throws {
        guard snapshot.configuration.endpoints.contains(where: {
            $0.id == endpointID && $0.apiKeys.contains(where: { $0.id == keyID })
        }) else { throw ConfigurationError.invalidValue("Endpoint API key not found: \(keyID.uuidString)") }
        let cleanSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSecret.isEmpty else {
            throw ConfigurationError.invalidValue("Enter an API key.")
        }
        try secretStore().setToken(cleanSecret, for: keyID)
        setEndpointCredentialAvailable(true, keyID: keyID)
        let endpoint = snapshot.configuration.endpoints.first { $0.id == endpointID }
        if endpoint?.activeAPIKeyID == keyID, endpoint?.enabled == true {
            await inspectEndpoint(endpointID)
            await reconcileGatewayAfterCredentialChange()
        }
    }

    public func selectEndpointAPIKey(_ keyID: UUID, endpointID: UUID) async throws {
        var candidate = snapshot.configuration
        guard let index = candidate.endpoints.firstIndex(where: { $0.id == endpointID }),
              candidate.endpoints[index].apiKeys.contains(where: { $0.id == keyID }) else { return }
        candidate.endpoints[index].activeAPIKeyID = keyID
        try await saveConfiguration(candidate)
        if candidate.endpoints[index].enabled { await inspectEndpoint(endpointID) }
    }

    public func removeEndpointAPIKey(_ keyID: UUID, endpointID: UUID) async throws {
        var candidate = snapshot.configuration
        guard let index = candidate.endpoints.firstIndex(where: { $0.id == endpointID }),
              candidate.endpoints[index].apiKeys.contains(where: { $0.id == keyID }) else { return }
        candidate.endpoints[index].apiKeys.removeAll { $0.id == keyID }
        if candidate.endpoints[index].activeAPIKeyID == keyID {
            candidate.endpoints[index].activeAPIKeyID = candidate.endpoints[index].apiKeys.first?.id
        }
        _ = try candidate.validated()
        let previous = try secretStore().token(for: keyID)
        try secretStore().setToken(nil, for: keyID)
        do {
            try await saveConfiguration(candidate)
        } catch {
            try? secretStore().setToken(previous, for: keyID)
            throw error
        }
        if candidate.endpoints[index].enabled { await inspectEndpoint(endpointID) }
        setEndpointCredentialAvailable(false, keyID: keyID)
    }

    public func hasToken(forAPIKey keyID: UUID) -> Bool {
        snapshot.availableEndpointAPIKeyIDs.contains(keyID)
    }

    public func hasToken(for endpointID: UUID) -> Bool {
        guard let endpoint = snapshot.configuration.endpoints.first(where: { $0.id == endpointID }),
              let keyID = endpoint.activeAPIKeyID else { return false }
        return hasToken(forAPIKey: keyID)
    }

    /// Duplicates a direct endpoint and every stored API-key credential as one
    /// rollback-safe transaction. Callers receive only the new endpoint ID.
    @discardableResult
    public func duplicateEndpoint(_ endpointID: UUID) async throws -> UUID {
        guard let source = snapshot.configuration.endpoints.first(where: { $0.id == endpointID }) else {
            throw SessionError.endpointNotFound(endpointID)
        }
        guard EndpointInteractionPolicy.canDuplicate(source) else {
            throw ConfigurationError.invalidValue("Only direct HTTPS API endpoints can be duplicated.")
        }

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

        let credentials = try source.apiKeys.compactMap { key -> (UUID, String)? in
            guard let secret = try secretStore().token(for: key.id), !secret.isEmpty else { return nil }
            return (keyIDMap[key.id]!, secret)
        }
        var candidate = snapshot.configuration
        candidate.endpoints.append(copy)
        _ = try candidate.validated()

        var writtenCredentialIDs: [UUID] = []
        do {
            for (keyID, secret) in credentials {
                try secretStore().setToken(secret, for: keyID)
                writtenCredentialIDs.append(keyID)
            }
            try await saveConfiguration(candidate)
        } catch {
            for keyID in writtenCredentialIDs {
                try? secretStore().setToken(nil, for: keyID)
            }
            throw error
        }
        if copy.enabled { await inspectEndpoint(copy.id) }
        return copy.id
    }

    /// Persists an SSH tunnel and its endpoint credential atomically. Runtime
    /// connection remains a separate typed command so a failed connection
    /// cannot make a successfully saved endpoint appear to have been lost.
    public func addSSHEndpoint(
        _ endpoint: APIEndpointConfiguration,
        tunnel: TunnelConfiguration,
        secret: String?
    ) async throws {
        var candidate = snapshot.configuration
        candidate.tunnels.append(tunnel)
        candidate.endpoints.append(endpoint)
        _ = try candidate.validated()

        let cleanSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentialID = endpoint.activeAPIKeyID ?? endpoint.id
        if cleanSecret?.isEmpty == false {
            try secretStore().setToken(cleanSecret, for: credentialID)
        }
        do {
            try await saveConfiguration(candidate)
        } catch {
            if cleanSecret?.isEmpty == false {
                try? secretStore().setToken(nil, for: credentialID)
            }
            throw error
        }
    }

    private func uniqueEndpointName(base: String) -> String {
        let cleanBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = cleanBase.isEmpty ? "Endpoint" : cleanBase
        let existing = Set(snapshot.configuration.endpoints.map { $0.name.lowercased() })
        guard existing.contains(candidate.lowercased()) else { return candidate }
        var suffix = 2
        while existing.contains("\(candidate) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(candidate) \(suffix)"
    }
}
