import Foundation
import ModelMoorCore

/// Account naming and token formatting shared by every secret store backend.
/// The account strings are part of the on-disk/on-Keychain contract and must
/// not change across platforms or releases.
public enum SecretStoreSupport {
    public static let productionService = "com.modelmoor.api-token"
    public static let legacyProductionService = "dev.modelmoor.api-token"
    public static let gatewayAccount = "gateway-client-token"
    public static let cliProxyManagementAccount = "cliproxy-management-password"
    public static let gatewayAPIKeyPrefix = "sk-"

    public static func gatewayAccount(for keyID: UUID) -> String {
        if keyID == GatewayAPIKeyConfiguration.defaultKeyID { return gatewayAccount }
        return "gateway-api-key-\(keyID.uuidString.lowercased())"
    }

    public static func endpointAccount(for endpointID: UUID) -> String {
        endpointID.uuidString
    }

    public static func formatGatewayAPIKey(_ bytes: [UInt8]) -> String {
        gatewayAPIKeyPrefix + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func makeSecureToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return formatGatewayAPIKey(bytes)
    }
}

/// Cross-platform secret storage contract. Platform backends store endpoint
/// API keys, Unified API keys and helper credentials; secrets never enter
/// configuration files, snapshots or logs.
public protocol ModelMoorSecretStore: EndpointSecretStore {
    /// Reads a secret by account name. Missing secrets return nil.
    func token(account: String) throws -> String?
    /// Stores or deletes (nil/empty) a secret by account name.
    func setToken(_ token: String?, account: String) throws
    /// Returns a variant that must not present interactive authentication UI.
    /// Backends without interaction concepts return themselves.
    func disallowingUserInteraction() -> any ModelMoorSecretStore
}

public extension ModelMoorSecretStore {
    func token(for endpointID: UUID) throws -> String? {
        try token(account: SecretStoreSupport.endpointAccount(for: endpointID))
    }

    func setToken(_ token: String?, for endpointID: UUID) throws {
        try setToken(token, account: SecretStoreSupport.endpointAccount(for: endpointID))
    }

    func ensureToken(for endpointID: UUID) throws -> String {
        if let existing = try token(for: endpointID), !existing.isEmpty { return existing }
        let generated = SecretStoreSupport.makeSecureToken()
        try setToken(generated, for: endpointID)
        return generated
    }

    func cliProxyManagementPassword() throws -> String? {
        try token(account: SecretStoreSupport.cliProxyManagementAccount)
    }

    func ensureCLIProxyManagementPassword() throws -> String {
        if let existing = try cliProxyManagementPassword(), !existing.isEmpty { return existing }
        let generated = SecretStoreSupport.makeSecureToken()
        try setToken(generated, account: SecretStoreSupport.cliProxyManagementAccount)
        return generated
    }

    func gatewayToken() throws -> String? {
        try gatewayAPIKey(for: GatewayAPIKeyConfiguration.defaultKeyID)
    }

    func ensureGatewayToken() throws -> String {
        try ensureGatewayAPIKey(for: GatewayAPIKeyConfiguration.defaultKeyID)
    }

    func gatewayAPIKey(for keyID: UUID) throws -> String? {
        try token(account: SecretStoreSupport.gatewayAccount(for: keyID))
    }

    func setGatewayToken(_ token: String?) throws {
        try setGatewayAPIKey(token, for: GatewayAPIKeyConfiguration.defaultKeyID)
    }

    func setGatewayAPIKey(_ token: String?, for keyID: UUID) throws {
        try setToken(token, account: SecretStoreSupport.gatewayAccount(for: keyID))
    }

    func ensureGatewayAPIKey(for keyID: UUID) throws -> String {
        if let existing = try gatewayAPIKey(for: keyID), !existing.isEmpty { return existing }
        let generated = SecretStoreSupport.makeSecureToken()
        try setGatewayAPIKey(generated, for: keyID)
        return generated
    }

    func rotateGatewayAPIKey(for keyID: UUID) throws -> String {
        let generated = SecretStoreSupport.makeSecureToken()
        try setGatewayAPIKey(generated, for: keyID)
        return generated
    }

    func enabledGatewayAPIKeys(for configuration: GatewayConfiguration) throws -> [String] {
        guard configuration.requiresAPIKey else { return [] }
        return try configuration.apiKeys.filter(\.enabled).map { try ensureGatewayAPIKey(for: $0.id) }
    }

    func endpointSecrets(for configuration: ModelMoorConfiguration) -> [UUID: String] {
        let plan = GatewayCredentialAccessPlan(configuration: configuration)
        let endpoints = Dictionary(uniqueKeysWithValues: configuration.endpoints.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: plan.endpointIDs.compactMap { endpointID in
            guard let keyID = endpoints[endpointID]?.activeAPIKeyID else { return nil }
            return (try? token(for: keyID)).map { (endpointID, $0) }
        })
    }

    func disallowingUserInteraction() -> any ModelMoorSecretStore { self }
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

public enum SecretStoreError: LocalizedError, Equatable {
    case unavailable(String)
    case permissionDenied(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .unavailable(detail): detail
        case let .permissionDenied(detail): detail
        case .cancelled: "Access to the secret store was cancelled."
        }
    }
}

/// Fallback used when no platform backend is enabled: reads report "no
/// secret", writes fail with the resolver's guidance. Lets read-only surfaces
/// (TUI snapshot, doctor) work before the user opts into a backend while
/// keeping writes fail-loud.
public struct UnavailableSecretStore: Sendable, ModelMoorSecretStore {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func token(account: String) throws -> String? { nil }

    public func setToken(_ token: String?, account: String) throws {
        if token == nil { return }  // deleting a nonexistent secret is a no-op
        throw SecretStoreError.unavailable(reason)
    }
}

/// Selects the platform secret store. macOS uses the Keychain. Linux uses the
/// explicit headless file backend only when the user opts in via
/// `MODELMOOR_SECRET_BACKEND=file`; otherwise resolution fails with guidance
/// instead of silently downgrading to plaintext storage. A Secret Service
/// adapter can be added behind this resolver once its D-Bus dependency passes
/// the milestone B vetting gate in docs/PLAN.md §7.
public enum SecretStoreResolver {
    public static let backendEnvironmentKey = "MODELMOOR_SECRET_BACKEND"
    public static let secretsFileEnvironmentKey = "MODELMOOR_SECRETS_FILE"

    /// Human-readable description of the backend `defaultStore` would select
    /// on this platform (used by diagnostics).
    public static var backendDescription: String {
        #if canImport(Security)
        return "macOS Keychain"
        #else
        return "headless file backend (explicit \(backendEnvironmentKey)=file opt-in)"
        #endif
    }

    public static func defaultStore(
        profile: ModelMoorRuntimeProfile = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any ModelMoorSecretStore {
        #if canImport(Security)
        return KeychainTokenStore(
            service: profile.secretService,
            fallbackServices: profile.legacySecretServices
        )
        #else
        guard let backend = environment[backendEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !backend.isEmpty else {
            throw SecretStoreError.unavailable(
                "No secret store backend is enabled. On Linux, ModelMoor stores API keys only after you explicitly enable the owner-only file backend: set \(backendEnvironmentKey)=file in the environment (secrets are kept in a 0600 file under the XDG data directory). A Secret Service adapter is planned; see docs/PLAN.md milestone B."
            )
        }
        guard backend == "file" else {
            throw SecretStoreError.unavailable(
                "Unknown \(backendEnvironmentKey) value \"\(backend)\". Supported value: file."
            )
        }
        return HeadlessFileSecretStore(fileURL: defaultSecretsFileURL(environment: environment))
        #endif
    }

    /// Default secrets file location for the Linux headless backend:
    /// `$MODELMOOR_SECRETS_FILE` > `$XDG_DATA_HOME/modelmoor/secrets.json` >
    /// `~/.local/share/modelmoor/secrets.json`.
    public static func defaultSecretsFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment[secretsFileEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return PlatformPaths.dataHome(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("modelmoor", isDirectory: true)
            .appendingPathComponent("secrets.json")
    }
}
