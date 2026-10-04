// OAuth flow details adapted from yetone/magpie (MIT License, Copyright 2026 yetone).
// See third_party/magpie/LICENSE for the full license text.
import Foundation
import ModelMoorCore
import NIOCore
import NIOHTTP1
import NIOPosix

public struct SubscriptionOAuthLogin: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case waiting
        case completed(account: SubscriptionAccountMetadata)
        case failed(String)
        case cancelled
    }

    public let id: UUID
    public let provider: SubscriptionOAuthProvider
    public let url: URL
    public let createdAt: Date
    public var state: State
}

/// Runs Codex/Claude OAuth callbacks on loopback and delegates Grok device
/// login to an isolated Grok Build profile. All credentials end in ModelMoor's
/// vault; user-owned CLI profiles are not read or changed.
public actor SubscriptionOAuthLoginCoordinator {
    private struct ActiveFlow {
        var login: SubscriptionOAuthLogin
        let authorization: SubscriptionOAuthAuthorization
        let callbackServer: SubscriptionOAuthCallbackServer
    }

    private let client: SubscriptionOAuthClient
    private let vault: SubscriptionCredentialVault
    private let grokCoordinator: GrokBuildSubscriptionLoginCoordinator
    private let kimiCoordinator: KimiCodeSubscriptionLoginCoordinator
    private var flows: [UUID: ActiveFlow] = [:]

    public init(
        vault: SubscriptionCredentialVault,
        client: SubscriptionOAuthClient = SubscriptionOAuthClient(),
        grokExecutableURL: URL? = GrokBuildSubscriptionAPIAdapter.findExecutable(),
        kimiExecutableURL: URL? = KimiCodeSubscriptionAPIAdapter.findExecutable()
    ) {
        self.vault = vault
        self.client = client
        self.grokCoordinator = GrokBuildSubscriptionLoginCoordinator(
            vault: vault,
            executableURL: grokExecutableURL
        )
        self.kimiCoordinator = KimiCodeSubscriptionLoginCoordinator(vault: vault, executableURL: kimiExecutableURL)
    }

    public func start(_ provider: SubscriptionOAuthProvider) async throws -> SubscriptionOAuthLogin {
        if provider == .xai { return try await grokCoordinator.start() }
        if provider == .kimi { return try await kimiCoordinator.start() }
        for id in Array(flows.keys) {
            await cancel(id)
        }
        let id = UUID()
        let server = try await SubscriptionOAuthCallbackServer.start(provider: provider) { [weak self] state, code, error in
            Task { await self?.receiveCallback(id: id, state: state, code: code, error: error) }
        }
        do {
            let authorization = try client.begin(provider: provider, redirectURI: server.redirectURI)
            let login = SubscriptionOAuthLogin(
                id: id,
                provider: provider,
                url: authorization.url,
                createdAt: Date(),
                state: .waiting
            )
            flows[id] = ActiveFlow(login: login, authorization: authorization, callbackServer: server)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(600))
                await self?.expire(id)
            }
            return login
        } catch {
            await server.stop()
            throw error
        }
    }

    public func status(_ id: UUID) async -> SubscriptionOAuthLogin? {
        if let login = flows[id]?.login { return login }
        if let login = await kimiCoordinator.status(id) { return login }
        return await grokCoordinator.status(id)
    }

    public func cancel(_ id: UUID) async {
        guard var flow = flows[id] else {
            await grokCoordinator.cancel(id)
            await kimiCoordinator.cancel(id)
            return
        }
        guard flow.login.state == .waiting else { return }
        flow.login.state = .cancelled
        flows[id] = flow
        await flow.callbackServer.stop()
    }

    private func expire(_ id: UUID) async {
        guard var flow = flows[id], flow.login.state == .waiting else { return }
        flow.login.state = .failed("Sign-in timed out. Start it again.")
        flows[id] = flow
        await flow.callbackServer.stop()
    }

    private func receiveCallback(id: UUID, state: String?, code: String?, error: String?) async {
        guard var flow = flows[id], flow.login.state == .waiting else { return }
        do {
            if let error, !error.isEmpty {
                throw SubscriptionOAuthError.tokenRequestFailed(status: 400, message: error)
            }
            guard let code, !code.isEmpty else { throw SubscriptionOAuthError.missingAuthorizationCode }
            guard let state else { throw SubscriptionOAuthError.callbackStateMismatch }
            let credential = try await client.exchange(
                authorization: flow.authorization,
                code: code,
                callbackState: state
            )
            let identity = try await client.identity(provider: flow.authorization.provider, credential: credential)
            let account = try await vault.save(
                provider: flow.authorization.provider,
                user: identity.user,
                plan: identity.plan,
                credential: credential
            )
            flow.login.state = .completed(account: account)
        } catch {
            flow.login.state = .failed(error.localizedDescription)
        }
        flows[id] = flow
        await flow.callbackServer.stop()
    }
}

public struct SubscriptionOAuthAccountIdentity: Equatable, Sendable {
    public let user: String
    public let plan: String?

    public init(user: String, plan: String? = nil) {
        self.user = user
        self.plan = plan
    }
}

extension SubscriptionOAuthClient {
    public func identity(
        provider: SubscriptionOAuthProvider,
        credential: SubscriptionOAuthCredential
    ) async throws -> SubscriptionOAuthAccountIdentity {
        switch provider {
        case .codex:
            guard let idToken = credential.idToken,
                  let payload = Self.jwtPayload(idToken) else {
                return SubscriptionOAuthAccountIdentity(user: "ChatGPT account")
            }
            let email = payload["email"] as? String
            let auth = payload["https://api.openai.com/auth"] as? [String: Any]
            let plan = auth?["chatgpt_plan_type"] as? String
            return SubscriptionOAuthAccountIdentity(user: email ?? "ChatGPT account", plan: plan)
        case .claude:
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return SubscriptionOAuthAccountIdentity(user: "Claude account")
            }
            let profile = try JSONDecoder().decode(ClaudeProfile.self, from: data)
            let plan = profile.organization?.organizationType
                .map { ["claude_max": "max", "claude_pro": "pro", "claude_team": "team", "claude_enterprise": "enterprise"][$0] ?? $0 }
            return SubscriptionOAuthAccountIdentity(
                user: profile.account?.email ?? "Claude account",
                plan: plan
            )
        case .xai:
            throw SubscriptionOAuthError.unsupportedProvider(.xai)
        case .kimi:
            throw SubscriptionOAuthError.unsupportedProvider(.kimi)
        }
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

    private struct ClaudeProfile: Decodable {
        let account: Account?
        let organization: Organization?

        struct Account: Decodable { let email: String? }
        struct Organization: Decodable {
            let organizationType: String?
            enum CodingKeys: String, CodingKey { case organizationType = "organization_type" }
        }
    }
}

private final class SubscriptionOAuthCallbackServer: @unchecked Sendable {
    let redirectURI: URL
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(redirectURI: URL, group: MultiThreadedEventLoopGroup, channel: Channel) {
        self.redirectURI = redirectURI
        self.group = group
        self.channel = channel
    }

    static func start(
        provider: SubscriptionOAuthProvider,
        callback: @escaping @Sendable (String?, String?, String?) -> Void
    ) async throws -> SubscriptionOAuthCallbackServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let requestedPort = provider == .codex ? 1_455 : 0
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(.backlog, value: 8)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(SubscriptionOAuthCallbackHandler(callback: callback))
                    }
                }
                .bind(host: "127.0.0.1", port: requestedPort)
                .get()
            guard let port = channel.localAddress?.port else {
                try? await channel.close().get()
                try? await group.shutdownGracefully()
                throw SubscriptionOAuthError.invalidAuthorizationURL
            }
            let path = provider == .codex ? "/auth/callback" : "/callback"
            guard let redirectURI = URL(string: "http://localhost:\(port)\(path)") else {
                try? await channel.close().get()
                try? await group.shutdownGracefully()
                throw SubscriptionOAuthError.invalidAuthorizationURL
            }
            return SubscriptionOAuthCallbackServer(redirectURI: redirectURI, group: group, channel: channel)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }
}

private final class SubscriptionOAuthCallbackHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let callback: @Sendable (String?, String?, String?) -> Void
    private var requestTarget: String?

    init(callback: @escaping @Sendable (String?, String?, String?) -> Void) {
        self.callback = callback
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            requestTarget = head.uri
        case .body:
            break
        case .end:
            finish(context: context)
        }
    }

    private func finish(context: ChannelHandlerContext) {
        let target = requestTarget ?? "/"
        let components = URLComponents(string: "http://localhost\(target)")
        guard let path = components?.path,
              path == "/callback" || path == "/auth/callback" else {
            respond(context: context, status: .notFound, text: "This sign-in callback was not found.")
            return
        }
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, latest in latest })
        callback(query["state"], query["code"], query["error_description"] ?? query["error"])
        respond(
            context: context,
            status: .ok,
            text: "Sign-in received. You can close this page and return to ModelMoor."
        )
    }

    private func respond(context: ChannelHandlerContext, status: HTTPResponseStatus, text: String) {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/plain; charset=utf-8")
        headers.add(name: "cache-control", value: "no-store")
        let response = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        context.write(wrapOutboundOut(.head(response)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }
}
