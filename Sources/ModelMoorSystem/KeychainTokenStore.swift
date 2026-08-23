import Foundation
import ModelMoorCore
#if canImport(Security)
import LocalAuthentication
import Security

public enum KeychainUserInteraction: Equatable, Sendable {
    case allow
    case disallow
}

/// macOS Keychain backend for `ModelMoorSecretStore`. All endpoint keys,
/// Unified API keys and helper credentials live in the user's login Keychain;
/// nothing secret is written to configuration files.
public struct KeychainTokenStore: Sendable, ModelMoorSecretStore {
    public static let productionService = SecretStoreSupport.productionService
    public static let legacyProductionService = SecretStoreSupport.legacyProductionService
    public static let gatewayAccount = SecretStoreSupport.gatewayAccount
    public static let cliProxyManagementAccount = SecretStoreSupport.cliProxyManagementAccount
    public static let gatewayAPIKeyPrefix = SecretStoreSupport.gatewayAPIKeyPrefix

    public var service: String
    public var fallbackServices: [String]
    public var userInteraction: KeychainUserInteraction

    public init(
        service: String = Self.productionService,
        fallbackServices: [String]? = nil,
        userInteraction: KeychainUserInteraction = .allow
    ) {
        self.service = service
        self.fallbackServices = fallbackServices
            ?? (service == Self.productionService ? [Self.legacyProductionService] : [])
        self.userInteraction = userInteraction
    }

    public func disallowingUserInteraction() -> Self {
        var copy = self
        copy.userInteraction = .disallow
        return copy
    }

    static func formatGatewayAPIKey(_ bytes: [UInt8]) -> String {
        SecretStoreSupport.formatGatewayAPIKey(bytes)
    }

    public func token(account: String) throws -> String? {
        if let current = try token(account: account, service: service) { return current }
        for fallbackService in fallbackServices where fallbackService != service {
            if let fallback = try token(account: account, service: fallbackService) { return fallback }
        }
        return nil
    }

    private func token(account: String, service: String) throws -> String? {
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
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            throw SecretStoreError.cancelled
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainTokenError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func setToken(_ token: String?, account: String) throws {
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
#endif
