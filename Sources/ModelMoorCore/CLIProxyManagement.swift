import Foundation

public enum CLIProxyLoginProvider: String, CaseIterable, Codable, Equatable, Sendable {
    case codex
    case claude
    case antigravity
    case kimi
    case xai

    public var displayName: String {
        switch self {
        case .codex: "ChatGPT / Codex"
        case .claude: "Claude Code"
        case .antigravity: "Google Antigravity"
        case .kimi: "Kimi"
        case .xai: "xAI / Grok"
        }
    }

    var managementPath: String {
        switch self {
        case .codex: "/codex-auth-url?is_webui=true"
        case .claude: "/anthropic-auth-url?is_webui=true"
        case .antigravity: "/antigravity-auth-url?is_webui=true"
        case .kimi: "/kimi-auth-url"
        case .xai: "/xai-auth-url"
        }
    }
}

public struct CLIProxyLoginSession: Decodable, Equatable, Sendable {
    public var status: String
    public var url: URL
    public var state: String
    public var flow: String?
    public var userCode: String?
    public var expiresIn: Int?

    private enum CodingKeys: String, CodingKey {
        case status, url, state, flow
        case userCode = "user_code"
        case expiresIn = "expires_in"
    }
}

public struct CLIProxyAuthStatus: Decodable, Equatable, Sendable {
    public var status: String
    public var error: String?
}

public struct CLIProxyAccount: Decodable, Identifiable, Equatable, Sendable {
    public var id: String
    public var authIndex: String?
    public var name: String
    public var provider: String
    public var label: String?
    public var status: String?
    public var statusMessage: String?
    public var disabled: Bool
    public var email: String?
    public var accountType: String?
    public var account: String?
    public var lastRefresh: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, label, status, disabled, email, account
        case authIndex = "auth_index"
        case statusMessage = "status_message"
        case accountType = "account_type"
        case lastRefresh = "last_refresh"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown account"
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? name
        authIndex = try container.decodeIfPresent(String.self, forKey: .authIndex)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "unknown"
        label = try container.decodeIfPresent(String.self, forKey: .label)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        email = try container.decodeIfPresent(String.self, forKey: .email)
        accountType = try container.decodeIfPresent(String.self, forKey: .accountType)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        lastRefresh = try container.decodeIfPresent(String.self, forKey: .lastRefresh)
    }
}

public struct CLIProxyManagementClient: Sendable {
    public let port: Int
    public let managementPassword: String
    public let session: URLSession

    public init(port: Int, managementPassword: String, session: URLSession = .shared) {
        self.port = port
        self.managementPassword = managementPassword
        self.session = session
    }

    public func startLogin(_ provider: CLIProxyLoginProvider) async throws -> CLIProxyLoginSession {
        try await send(path: provider.managementPath)
    }

    public func loginStatus(state: String) async throws -> CLIProxyAuthStatus {
        try await send(path: "/get-auth-status?state=\(encodedQueryValue(state))")
    }

    public func cancelLogin(state: String) async throws {
        let _: StatusResponse = try await send(
            path: "/oauth-session?state=\(encodedQueryValue(state))",
            method: "DELETE"
        )
    }

    public func accounts() async throws -> [CLIProxyAccount] {
        let response: AuthFilesResponse = try await send(path: "/auth-files")
        return response.files.filter {
            Self.subscriptionAccountProviders.contains($0.provider.lowercased())
        }
    }

    static let subscriptionAccountProviders: Set<String> = [
        "codex",
        "claude",
        "antigravity",
        "kimi",
        "xai",
        // CLIProxyAPI can load Gemini CLI credentials even though the pinned
        // management API does not currently expose a browser-login route.
        "gemini",
        "gemini-cli"
    ]

    public func deleteAccount(named name: String) async throws {
        let _: StatusResponse = try await send(
            path: "/auth-files?name=\(encodedQueryValue(name))",
            method: "DELETE"
        )
    }

    public func setAccountDisabled(_ account: CLIProxyAccount, disabled: Bool) async throws {
        let body = try JSONEncoder().encode(
            AccountStatusRequest(
                name: account.name,
                authIndex: account.authIndex,
                disabled: disabled
            )
        )
        let _: StatusResponse = try await send(
            path: "/auth-files/status",
            method: "PATCH",
            body: body
        )
    }

    private func send<Response: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Response {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v0/management\(path)") else {
            throw CLIProxyManagementError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 10
        request.setValue("Bearer \(managementPassword)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CLIProxyManagementError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw CLIProxyManagementError.server(status: http.statusCode, message: message)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CLIProxyManagementError.decoding(error.localizedDescription)
        }
    }

    private func encodedQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private struct AuthFilesResponse: Decodable { let files: [CLIProxyAccount] }
    private struct AccountStatusRequest: Encodable {
        let name: String
        let authIndex: String?
        let disabled: Bool

        private enum CodingKeys: String, CodingKey {
            case name, disabled
            case authIndex = "auth_index"
        }
    }
    private struct StatusResponse: Decodable { let status: String }
    private struct ErrorResponse: Decodable { let error: String }
}

public enum CLIProxyManagementError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case server(status: Int, message: String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "CLIProxyAPI management URL is invalid."
        case .invalidResponse: "CLIProxyAPI returned an invalid response."
        case let .server(status, message): "CLIProxyAPI management request failed (\(status)): \(message)"
        case let .decoding(message): "CLIProxyAPI response could not be read: \(message)"
        }
    }
}
