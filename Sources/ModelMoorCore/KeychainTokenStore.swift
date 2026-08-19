import Foundation
import LocalAuthentication
import Security

public enum KeychainUserInteraction: Equatable, Sendable {
    case allow
    case disallow
}

public struct GatewayCredentialAccessPlan: Equatable, Sendable {
    public let gatewayAPIKeyIDs: [UUID]
    public let endpointIDs: [UUID]

    public init(configuration: ModelMoorConfiguration) {
        gatewayAPIKeyIDs = configuration.gateway.requiresAPIKey
            ? configuration.gateway.apiKeys.filter(\.enabled).map(\.id)
            : []

        let routedEndpointIDs = Set(
            configuration.routes.filter(\.enabled).map(\.endpointID)
        )
        endpointIDs = configuration.endpoints.filter {
            $0.enabled
                && $0.authentication != .none
                && routedEndpointIDs.contains($0.id)
        }.map(\.id)
    }
}

public struct KeychainTokenStore: Sendable, EndpointSecretStore {
    public static let gatewayAccount = "gateway-client-token"
    public static let gatewayAPIKeyPrefix = "sk-"
    public var service: String
    public var userInteraction: KeychainUserInteraction

    public init(
        service: String = "dev.modelmoor.api-token",
        userInteraction: KeychainUserInteraction = .allow
    ) {
        self.service = service
        self.userInteraction = userInteraction
    }

    public func disallowingUserInteraction() -> Self {
        var copy = self
        copy.userInteraction = .disallow
        return copy
    }

    public func token(for endpointID: UUID) throws -> String? {
        try token(account: endpointID.uuidString)
    }

    public func gatewayToken() throws -> String? {
        try gatewayAPIKey(for: GatewayAPIKeyConfiguration.defaultKeyID)
    }

    public func ensureGatewayToken() throws -> String {
        try ensureGatewayAPIKey(for: GatewayAPIKeyConfiguration.defaultKeyID)
    }

    public func gatewayAPIKey(for keyID: UUID) throws -> String? {
        try token(account: gatewayAccount(for: keyID))
    }

    public func ensureGatewayAPIKey(for keyID: UUID) throws -> String {
        if let existing = try gatewayAPIKey(for: keyID), !existing.isEmpty { return existing }
        let generated = try makeSecureToken()
        try setGatewayAPIKey(generated, for: keyID)
        return generated
    }

    public func rotateGatewayAPIKey(for keyID: UUID) throws -> String {
        let generated = try makeSecureToken()
        try setGatewayAPIKey(generated, for: keyID)
        return generated
    }

    public func enabledGatewayAPIKeys(for configuration: GatewayConfiguration) throws -> [String] {
        guard configuration.requiresAPIKey else { return [] }
        return try configuration.apiKeys.filter(\.enabled).map { try ensureGatewayAPIKey(for: $0.id) }
    }

    public func endpointSecrets(for configuration: ModelMoorConfiguration) -> [UUID: String] {
        let plan = GatewayCredentialAccessPlan(configuration: configuration)
        let endpoints = Dictionary(uniqueKeysWithValues: configuration.endpoints.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: plan.endpointIDs.compactMap { endpointID in
            guard let keyID = endpoints[endpointID]?.activeAPIKeyID else { return nil }
            return (try? token(for: keyID)).map { (endpointID, $0) }
        })
    }

    private func makeSecureToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainTokenError(status: status) }
        return Self.formatGatewayAPIKey(bytes)
    }

    static func formatGatewayAPIKey(_ bytes: [UInt8]) -> String {
        Self.gatewayAPIKeyPrefix + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func token(account: String) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        applyAuthenticationPolicy(to: &query)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainTokenError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func setToken(_ token: String?, for endpointID: UUID) throws {
        try setToken(token, account: endpointID.uuidString)
    }

    public func setGatewayToken(_ token: String?) throws {
        try setGatewayAPIKey(token, for: GatewayAPIKeyConfiguration.defaultKeyID)
    }

    public func setGatewayAPIKey(_ token: String?, for keyID: UUID) throws {
        try setToken(token, account: gatewayAccount(for: keyID))
    }

    private func gatewayAccount(for keyID: UUID) -> String {
        if keyID == GatewayAPIKeyConfiguration.defaultKeyID { return Self.gatewayAccount }
        return "gateway-api-key-\(keyID.uuidString.lowercased())"
    }

    private func setToken(_ token: String?, account: String) throws {
        var key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        applyAuthenticationPolicy(to: &key)
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            let status = SecItemDelete(key as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainTokenError(status: status)
            }
            return
        }

        let data = Data(trimmed.utf8)
        let protectedAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(
            key as CFDictionary,
            protectedAttributes as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var item = key
            protectedAttributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainTokenError(status: addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainTokenError(status: updateStatus)
        }
    }

    private func applyAuthenticationPolicy(to query: inout [String: Any]) {
        guard userInteraction == .disallow else { return }
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
    }
}

public struct KeychainTokenError: LocalizedError, Equatable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "Keychain: \(message)"
        }
        return "Keychain error \(status)"
    }
}
