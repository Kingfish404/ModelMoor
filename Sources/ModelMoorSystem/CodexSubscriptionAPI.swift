// Codex subscription request details adapted from yetone/magpie (MIT License,
// Copyright 2026 yetone). See Support/Licenses/Magpie-LICENSE.txt.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SubscriptionModel: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let supportedReasoningLevels: [String]

    public init(id: String, name: String, supportedReasoningLevels: [String] = []) {
        self.id = id
        self.name = name
        self.supportedReasoningLevels = supportedReasoningLevels
    }
}

public struct SubscriptionAPIRequest: Equatable, Sendable {
    public let method: String
    public let pathAndQuery: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, pathAndQuery: String, headers: [String: String], body: Data) {
        self.method = method
        self.pathAndQuery = pathAndQuery
        self.headers = headers
        self.body = body
    }
}

public enum SubscriptionAPIAdapterError: LocalizedError, Equatable {
    case unsupportedRequest(provider: SubscriptionOAuthProvider, method: String, path: String)
    case invalidCredential(provider: SubscriptionOAuthProvider)
    case invalidRequestBody
    case accountDoesNotExposeModels
    case upstream(status: Int, message: String)
    case invalidModelList

    public var errorDescription: String? {
        switch self {
        case let .unsupportedRequest(provider, method, path):
            "\(provider.displayName) subscription routing does not support \(method) \(path) yet."
        case let .invalidCredential(provider):
            "The ModelMoor-managed \(provider.displayName) credential is incomplete. Sign in again."
        case .invalidRequestBody:
            "The subscription request body is not a valid JSON object."
        case let .upstream(status, message):
            "The subscription provider returned HTTP \(status): \(message)"
        case .accountDoesNotExposeModels:
            "The subscription account does not have any available Codex models."
        case .invalidModelList:
            "The subscription provider returned an unreadable model list."
        }
    }
}

/// Direct Codex/ChatGPT subscription adapter. It authenticates with a token
/// held in ModelMoor's vault and emits the ChatGPT Responses API request that
/// the subscription backend accepts. It does not read the Codex CLI profile.
public struct CodexSubscriptionAPIAdapter: Sendable {
    public static let backend = URL(string: "https://chatgpt.com/backend-api/codex")!
    public static let clientVersion = "0.159.0"

    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func models(using credential: SubscriptionOAuthCredential) async throws -> [SubscriptionModel] {
        let accountID = try Self.accountID(from: credential)
        var components = URLComponents(url: Self.backend.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "client_version", value: Self.clientVersion)]
        guard let url = components.url else { throw SubscriptionAPIAdapterError.invalidModelList }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCodexHeaders(to: &request, credential: credential, accountID: accountID)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SubscriptionAPIAdapterError.invalidModelList }
        guard (200...299).contains(http.statusCode) else {
            throw SubscriptionAPIAdapterError.upstream(
                status: http.statusCode,
                message: Self.errorMessage(data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
        let result = try JSONDecoder().decode(ModelListResponse.self, from: data)
        let models = result.models.compactMap { model -> SubscriptionModel? in
            guard !model.slug.isEmpty, model.visibility != "hide" else { return nil }
            return SubscriptionModel(
                id: model.slug,
                name: model.displayName.isEmpty ? model.slug : model.displayName,
                supportedReasoningLevels: model.supportedReasoningLevels.map(\.effort).filter { !$0.isEmpty }
            )
        }
        guard !models.isEmpty else { throw SubscriptionAPIAdapterError.accountDoesNotExposeModels }
        return models
    }

    public func prepare(
        _ request: SubscriptionAPIRequest,
        credential: SubscriptionOAuthCredential,
        upstreamModel: String
    ) throws -> URLRequest {
        let path = URLComponents(string: request.pathAndQuery)?.path ?? request.pathAndQuery
        guard request.method.uppercased() == "POST", path == "/v1/responses" else {
            throw SubscriptionAPIAdapterError.unsupportedRequest(
                provider: .codex,
                method: request.method,
                path: path
            )
        }
        guard !upstreamModel.isEmpty else { throw SubscriptionAPIAdapterError.invalidCredential(provider: .codex) }
        guard var object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            throw SubscriptionAPIAdapterError.invalidRequestBody
        }
        let accountID = try Self.accountID(from: credential)
        let model = upstreamModel.hasPrefix("codex/") ? String(upstreamModel.dropFirst("codex/".count)) : upstreamModel
        object["model"] = model
        let body = try JSONSerialization.data(withJSONObject: object)
        var components = URLComponents(
            url: Self.backend.appendingPathComponent("responses"),
            resolvingAgainstBaseURL: false
        )
        components?.percentEncodedQuery = URLComponents(string: request.pathAndQuery)?.percentEncodedQuery
        guard let upstreamURL = components?.url else {
            throw SubscriptionAPIAdapterError.unsupportedRequest(provider: .codex, method: request.method, path: path)
        }
        var prepared = URLRequest(url: upstreamURL)
        prepared.httpMethod = "POST"
        prepared.httpBody = body
        prepared.timeoutInterval = 300
        for (name, value) in request.headers {
            let lower = name.lowercased()
            guard !["authorization", "host", "content-length", "connection", "accept-encoding"].contains(lower) else { continue }
            prepared.setValue(value, forHTTPHeaderField: name)
        }
        prepared.setValue("application/json", forHTTPHeaderField: "Content-Type")
        prepared.setValue(
            object["stream"] as? Bool == true ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept"
        )
        applyCodexHeaders(to: &prepared, credential: credential, accountID: accountID)
        if let cacheKey = object["prompt_cache_key"] as? String, !cacheKey.isEmpty {
            prepared.setValue(cacheKey, forHTTPHeaderField: "session_id")
            prepared.setValue(cacheKey, forHTTPHeaderField: "conversation_id")
        }
        return prepared
    }

    private func applyCodexHeaders(
        to request: inout URLRequest,
        credential: SubscriptionOAuthCredential,
        accountID: String
    ) {
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "version")
        request.setValue("codex_cli_rs/\(Self.clientVersion)", forHTTPHeaderField: "User-Agent")
    }

    private static func accountID(from credential: SubscriptionOAuthCredential) throws -> String {
        guard !credential.accessToken.isEmpty,
              let token = credential.idToken,
              let payload = jwtPayload(token),
              let auth = payload["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String,
              !accountID.isEmpty else {
            throw SubscriptionAPIAdapterError.invalidCredential(provider: .codex)
        }
        return accountID
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let pieces = token.split(separator: ".")
        guard pieces.count > 1 else { return nil }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return object["message"] as? String
    }

    private struct ModelListResponse: Decodable {
        let models: [Model]
        struct Model: Decodable {
            let slug: String
            let displayName: String
            let visibility: String?
            let supportedReasoningLevels: [ReasoningLevel]
            enum CodingKeys: String, CodingKey {
                case slug, visibility
                case displayName = "display_name"
                case supportedReasoningLevels = "supported_reasoning_levels"
            }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                slug = try container.decodeIfPresent(String.self, forKey: .slug) ?? ""
                displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
                visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
                supportedReasoningLevels = try container.decodeIfPresent([ReasoningLevel].self, forKey: .supportedReasoningLevels) ?? []
            }
        }
        struct ReasoningLevel: Decodable { let effort: String }
    }
}
