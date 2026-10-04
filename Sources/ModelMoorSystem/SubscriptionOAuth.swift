// OAuth flow details adapted from yetone/magpie (MIT License, Copyright 2026 yetone).
// See Support/Licenses/Magpie-LICENSE.txt for the full license text.
import Foundation
import ModelMoorCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Providers whose subscription accounts are managed by ModelMoor. Codex and
/// Claude use OAuth PKCE; xAI and Kimi use isolated first-party CLI logins.
public enum SubscriptionOAuthProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case codex
    case claude
    case kimi
    case xai

    public var displayName: String {
        switch self {
        case .codex: "ChatGPT / Codex"
        case .claude: "Claude"
        case .kimi: "Kimi Code"
        case .xai: "xAI / Grok Build"
        }
    }
}

public struct SubscriptionOAuthAuthorization: Codable, Equatable, Sendable {
    public let id: UUID
    public let provider: SubscriptionOAuthProvider
    public let url: URL
    public let redirectURI: URL
    public let state: String
    public let codeVerifier: String
    public let createdAt: Date

    fileprivate init(
        id: UUID = UUID(),
        provider: SubscriptionOAuthProvider,
        url: URL,
        redirectURI: URL,
        state: String,
        codeVerifier: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.url = url
        self.redirectURI = redirectURI
        self.state = state
        self.codeVerifier = codeVerifier
        self.createdAt = createdAt
    }
}

/// Subscription credentials are stored only in ModelMoor's secret store.
/// Never put this value in configuration JSON, snapshots, diagnostics, or
/// local agent files. For xAI, the refreshToken field carries a base64 auth
/// document because Grok rotates its token fields together.
public struct SubscriptionOAuthCredential: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var idToken: String?
    public var expiresAt: Date?
    public var scopes: [String]

    public init(
        accessToken: String,
        refreshToken: String,
        idToken: String? = nil,
        expiresAt: Date? = nil,
        scopes: [String] = []
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    public var needsRefresh: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date().addingTimeInterval(300)
    }
}

public struct SubscriptionAccountMetadata: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let provider: SubscriptionOAuthProvider
    public let user: String
    public let plan: String?
    public var enabled: Bool
    public let addedAt: Date

    public init(
        id: UUID = UUID(),
        provider: SubscriptionOAuthProvider,
        user: String,
        plan: String? = nil,
        enabled: Bool = true,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.user = user
        self.plan = plan
        self.enabled = enabled
        self.addedAt = addedAt
    }
}

public enum SubscriptionOAuthError: LocalizedError, Equatable {
    case unsupportedProvider(SubscriptionOAuthProvider)
    case unsupportedCrypto
    case invalidAuthorizationURL
    case callbackStateMismatch
    case missingAuthorizationCode
    case tokenRequestFailed(status: Int, message: String)
    case invalidTokenResponse
    case accountNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(provider):
            "\(provider.displayName) sign-in uses its native CLI flow rather than OAuth PKCE."
        case .unsupportedCrypto:
            "Secure PKCE hashing is unavailable on this platform."
        case .invalidAuthorizationURL:
            "Could not construct the provider sign-in URL."
        case .callbackStateMismatch:
            "The sign-in callback did not match the active OAuth session."
        case .missingAuthorizationCode:
            "The provider did not return an authorization code."
        case let .tokenRequestFailed(status, message):
            "The provider rejected the token request (HTTP \(status)): \(message)"
        case .invalidTokenResponse:
            "The provider returned an incomplete token response."
        case let .accountNotFound(id):
            "Subscription account not found: \(id.uuidString)"
        }
    }
}

/// Implements the provider OAuth exchanges without importing or modifying an
/// agent's credential format. The redirect URI is selected by the caller's
/// loopback callback server and must be reused for the token exchange.
public struct SubscriptionOAuthClient: Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func begin(
        provider: SubscriptionOAuthProvider,
        redirectURI: URL
    ) throws -> SubscriptionOAuthAuthorization {
        guard provider != .xai else { throw SubscriptionOAuthError.unsupportedProvider(provider) }
        let verifier = Self.randomURLSafeToken(byteCount: 48)
        let state = Self.randomURLSafeToken(byteCount: 24)
        let challenge = try Self.pkceChallenge(verifier)
        var components = URLComponents(string: provider == .codex
            ? "https://auth.openai.com/oauth/authorize"
            : "https://claude.com/cai/oauth/authorize")
        guard components != nil else { throw SubscriptionOAuthError.invalidAuthorizationURL }

        var query = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID(for: provider)),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        switch provider {
        case .codex:
            query += [
                URLQueryItem(name: "scope", value: "openid profile email offline_access api.connectors.read api.connectors.invoke"),
                URLQueryItem(name: "id_token_add_organizations", value: "true"),
                URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
                URLQueryItem(name: "originator", value: "codex_cli_rs")
            ]
        case .claude:
            query += [
                URLQueryItem(name: "code", value: "true"),
                URLQueryItem(name: "scope", value: "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload user:plugins")
            ]
        case .xai, .kimi:
            throw SubscriptionOAuthError.unsupportedProvider(provider)
        }
        components?.queryItems = query
        guard let url = components?.url else { throw SubscriptionOAuthError.invalidAuthorizationURL }
        return SubscriptionOAuthAuthorization(
            provider: provider,
            url: url,
            redirectURI: redirectURI,
            state: state,
            codeVerifier: verifier
        )
    }

    public func exchange(
        authorization: SubscriptionOAuthAuthorization,
        code: String,
        callbackState: String
    ) async throws -> SubscriptionOAuthCredential {
        guard callbackState == authorization.state else {
            throw SubscriptionOAuthError.callbackStateMismatch
        }
        guard !code.isEmpty else { throw SubscriptionOAuthError.missingAuthorizationCode }

        let body: Data
        let contentType: String
        switch authorization.provider {
        case .codex:
            var values = URLComponents()
            values.queryItems = [
                URLQueryItem(name: "grant_type", value: "authorization_code"),
                URLQueryItem(name: "code", value: code),
                URLQueryItem(name: "redirect_uri", value: authorization.redirectURI.absoluteString),
                URLQueryItem(name: "client_id", value: Self.clientID(for: authorization.provider)),
                URLQueryItem(name: "code_verifier", value: authorization.codeVerifier)
            ]
            body = Data((values.percentEncodedQuery ?? "").utf8)
            contentType = "application/x-www-form-urlencoded"
        case .claude:
            body = try JSONSerialization.data(withJSONObject: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": authorization.redirectURI.absoluteString,
                "client_id": Self.clientID(for: authorization.provider),
                "code_verifier": authorization.codeVerifier,
                "state": authorization.state
            ])
            contentType = "application/json"
        case .xai, .kimi:
            throw SubscriptionOAuthError.unsupportedProvider(authorization.provider)
        }
        return try await tokenRequest(
            provider: authorization.provider,
            body: body,
            contentType: contentType
        )
    }

    public func refresh(
        provider: SubscriptionOAuthProvider,
        refreshToken: String
    ) async throws -> SubscriptionOAuthCredential {
        let body: Data
        switch provider {
        case .codex, .claude:
            body = try JSONSerialization.data(withJSONObject: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": Self.clientID(for: provider)
            ])
        case .xai, .kimi:
            throw SubscriptionOAuthError.unsupportedProvider(provider)
        }
        return try await tokenRequest(
            provider: provider,
            body: body,
            contentType: "application/json",
            fallbackRefreshToken: refreshToken
        )
    }

    private func tokenRequest(
        provider: SubscriptionOAuthProvider,
        body: Data,
        contentType: String,
        fallbackRefreshToken: String? = nil
    ) async throws -> SubscriptionOAuthCredential {
        let endpoint = URL(string: provider == .codex
            ? "https://auth.openai.com/oauth/token"
            : "https://platform.claude.com/v1/oauth/token")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SubscriptionOAuthError.invalidTokenResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = Self.providerError(in: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw SubscriptionOAuthError.tokenRequestFailed(status: http.statusCode, message: message)
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard !token.accessToken.isEmpty,
              let refreshToken = token.refreshToken ?? fallbackRefreshToken,
              !refreshToken.isEmpty else {
            throw SubscriptionOAuthError.invalidTokenResponse
        }
        return SubscriptionOAuthCredential(
            accessToken: token.accessToken,
            refreshToken: refreshToken,
            idToken: token.idToken,
            expiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            scopes: token.scope?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
        )
    }

    private static func clientID(for provider: SubscriptionOAuthProvider) -> String {
        switch provider {
        case .codex: "app_EMoamEEZ73f0CkXaXp7hrann"
        case .claude: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        case .xai, .kimi: ""
        }
    }

    private static func randomURLSafeToken(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func pkceChallenge(_ verifier: String) throws -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #else
        throw SubscriptionOAuthError.unsupportedCrypto
        #endif
    }

    private static func providerError(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["error_description", "detail", "message"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        if let value = object["error"] as? String, !value.isEmpty { return value }
        return nil
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let expiresIn: Int?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case expiresIn = "expires_in"
            case scope
        }
    }
}

/// Secret-store-backed subscription account registry. Credentials never
/// touch a user's ordinary CLI home, Keychain item, or agent-owned state.
public actor SubscriptionCredentialVault {
    private static let indexKey = "subscription-oauth.accounts.v1"
    private static let credentialPrefix = "subscription-oauth.credential."

    private let secretStore: any ModelMoorSecretStore
    private var refreshTasks: [UUID: Task<SubscriptionOAuthCredential, Error>] = [:]

    public init(secretStore: any ModelMoorSecretStore) {
        self.secretStore = secretStore
    }

    public func accounts() throws -> [SubscriptionAccountMetadata] {
        try readIndex()
    }

    @discardableResult
    public func save(
        provider: SubscriptionOAuthProvider,
        user: String,
        plan: String? = nil,
        credential: SubscriptionOAuthCredential
    ) throws -> SubscriptionAccountMetadata {
        let normalizedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUser.isEmpty else { throw SubscriptionOAuthError.invalidTokenResponse }
        var index = try readIndex()
        let existingIndex = index.firstIndex {
            $0.provider == provider && $0.user.caseInsensitiveCompare(normalizedUser) == .orderedSame
        }
        var account = existingIndex.map { index[$0] }
            ?? SubscriptionAccountMetadata(provider: provider, user: normalizedUser, plan: plan)
        account.enabled = true
        if let existingIndex {
            index[existingIndex] = account
        } else {
            index.append(account)
        }
        let encodedCredential = try JSONEncoder().encode(credential)
        try secretStore.setToken(
            String(decoding: encodedCredential, as: UTF8.self),
            account: Self.credentialPrefix + account.id.uuidString.lowercased()
        )
        try writeIndex(index)
        return account
    }

    public func credential(for accountID: UUID) throws -> SubscriptionOAuthCredential {
        guard try readIndex().contains(where: { $0.id == accountID }) else {
            throw SubscriptionOAuthError.accountNotFound(accountID)
        }
        let key = Self.credentialPrefix + accountID.uuidString.lowercased()
        guard let encoded = try secretStore.token(account: key),
              let data = encoded.data(using: .utf8) else {
            throw SubscriptionOAuthError.accountNotFound(accountID)
        }
        return try JSONDecoder().decode(SubscriptionOAuthCredential.self, from: data)
    }

    /// Refreshes expiring credentials once per account and persists rotated
    /// refresh tokens before returning them to a request adapter.
    public func usableCredential(
        for accountID: UUID,
        using client: SubscriptionOAuthClient
    ) async throws -> SubscriptionOAuthCredential {
        let current = try credential(for: accountID)
        guard current.needsRefresh else { return current }
        let account = try readIndex().first { $0.id == accountID }
        guard let account else { throw SubscriptionOAuthError.accountNotFound(accountID) }
        let task: Task<SubscriptionOAuthCredential, Error>
        if let existing = refreshTasks[accountID] {
            task = existing
        } else {
            let created = Task {
                try await client.refresh(provider: account.provider, refreshToken: current.refreshToken)
            }
            refreshTasks[accountID] = created
            task = created
        }
        do {
            let refreshed = try await task.value
            try updateCredential(refreshed, for: accountID)
            refreshTasks[accountID] = nil
            return refreshed
        } catch {
            refreshTasks[accountID] = nil
            throw error
        }
    }

    public func updateCredential(
        _ credential: SubscriptionOAuthCredential,
        for accountID: UUID
    ) throws {
        guard try readIndex().contains(where: { $0.id == accountID }) else {
            throw SubscriptionOAuthError.accountNotFound(accountID)
        }
        let data = try JSONEncoder().encode(credential)
        try secretStore.setToken(
            String(decoding: data, as: UTF8.self),
            account: Self.credentialPrefix + accountID.uuidString.lowercased()
        )
    }

    public func setEnabled(_ enabled: Bool, for accountID: UUID) throws {
        var index = try readIndex()
        guard let position = index.firstIndex(where: { $0.id == accountID }) else {
            throw SubscriptionOAuthError.accountNotFound(accountID)
        }
        index[position].enabled = enabled
        try writeIndex(index)
    }

    public func remove(_ accountID: UUID) throws {
        let index = try readIndex()
        guard index.contains(where: { $0.id == accountID }) else {
            throw SubscriptionOAuthError.accountNotFound(accountID)
        }
        try writeIndex(index.filter { $0.id != accountID })
        refreshTasks[accountID]?.cancel()
        refreshTasks[accountID] = nil
        try secretStore.setToken(nil, account: Self.credentialPrefix + accountID.uuidString.lowercased())
    }

    private func readIndex() throws -> [SubscriptionAccountMetadata] {
        guard let raw = try secretStore.token(account: Self.indexKey),
              let data = raw.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([SubscriptionAccountMetadata].self, from: data)
    }

    private func writeIndex(_ accounts: [SubscriptionAccountMetadata]) throws {
        let data = try JSONEncoder().encode(accounts)
        try secretStore.setToken(String(decoding: data, as: UTF8.self), account: Self.indexKey)
    }
}
