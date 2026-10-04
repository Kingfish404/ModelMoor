import Foundation
import ModelMoorCore
import ModelMoorSystem

public enum ManagedSubscriptionError: LocalizedError, Equatable {
    case providerUnsupported(String)
    case accountUnavailable

    public var errorDescription: String? {
        switch self {
        case let .providerUnsupported(provider):
            "\(provider) does not have a ModelMoor-managed subscription route."
        case .accountUnavailable:
            "This subscription account is no longer available in ModelMoor's secret store."
        }
    }
}

public struct ManagedSubscriptionActionAvailability: Equatable, Sendable {
    public let canStartLogin: Bool
    public let canRefreshAccounts: Bool
    public let canMutateAccounts: Bool

    public init(
        canStartLogin: Bool,
        canRefreshAccounts: Bool,
        canMutateAccounts: Bool
    ) {
        self.canStartLogin = canStartLogin
        self.canRefreshAccounts = canRefreshAccounts
        self.canMutateAccounts = canMutateAccounts
    }
}

public enum ManagedSubscriptionInteractionPolicy {
    public static func availability(
        runtimeState: SessionRuntimeState,
        hasActiveLogin: Bool,
        hasAccounts: Bool
    ) -> ManagedSubscriptionActionAvailability {
        let ownsRuntime: Bool
        if case .running = runtimeState {
            ownsRuntime = true
        } else {
            ownsRuntime = false
        }
        return ManagedSubscriptionActionAvailability(
            canStartLogin: ownsRuntime && !hasActiveLogin,
            canRefreshAccounts: ownsRuntime,
            canMutateAccounts: ownsRuntime && hasAccounts
        )
    }
}

extension ModelMoorSession {
    public func startSubscriptionLogin(
        _ provider: SubscriptionProvider
    ) async throws -> SubscriptionLoginSession {
        guard ownsRuntime() else {
            throw SessionError.runtimeOwnedElsewhere(owner: recordedRuntimeOwner())
        }
        guard let nativeProvider = SubscriptionOAuthProvider(rawValue: provider.rawValue) else {
            throw ManagedSubscriptionError.providerUnsupported(provider.rawValue)
        }
        let nativeLogin = try await subscriptionOAuthLoginCoordinator.start(nativeProvider)
        let login = SubscriptionLoginSession(url: nativeLogin.url, state: nativeLogin.id.uuidString)
        snapshot.subscriptions.activeProvider = provider
        snapshot.subscriptions.activeLogin = login
        snapshot.subscriptions.errorMessage = nil
        emit()
        subscriptionOAuthLoginTask?.cancel()
        subscriptionOAuthLoginTask = Task { [weak self] in
            await self?.pollNativeSubscriptionLogin(nativeLogin.id)
        }
        return login
    }

    public func cancelSubscriptionLogin() async {
        guard let nativeLogin = snapshot.subscriptions.activeLogin,
              let loginID = UUID(uuidString: nativeLogin.state) else { return }
        subscriptionOAuthLoginTask?.cancel()
        subscriptionOAuthLoginTask = nil
        await subscriptionOAuthLoginCoordinator.cancel(loginID)
        snapshot.subscriptions.activeLogin = nil
        snapshot.subscriptions.activeProvider = nil
        emit()
    }

    public func refreshSubscriptionAccounts() async throws {
        guard ownsRuntime() else {
            throw SessionError.runtimeOwnedElsewhere(owner: recordedRuntimeOwner())
        }
        try await refreshNativeSubscriptionAccounts()
    }

    public func refreshSubscriptionState() async throws {
        try await refreshSubscriptionAccounts()
        try await refreshNativeSubscriptionModels()
    }

    public func removeSubscriptionAccount(_ account: SubscriptionAccount) async throws {
        guard ownsRuntime() else {
            throw SessionError.runtimeOwnedElsewhere(owner: recordedRuntimeOwner())
        }
        guard let accountID = UUID(uuidString: account.id),
              try await subscriptionCredentialVault.accounts().contains(where: { $0.id == accountID }) else {
            throw ManagedSubscriptionError.accountUnavailable
        }
        try await subscriptionCredentialVault.remove(accountID)
        try await refreshNativeSubscriptionAccounts()
        await reconcileGatewayAfterCredentialChange()
    }

    public func setSubscriptionAccountEnabled(
        _ account: SubscriptionAccount,
        enabled: Bool
    ) async throws {
        guard ownsRuntime() else {
            throw SessionError.runtimeOwnedElsewhere(owner: recordedRuntimeOwner())
        }
        guard let accountID = UUID(uuidString: account.id),
              try await subscriptionCredentialVault.accounts().contains(where: { $0.id == accountID }) else {
            throw ManagedSubscriptionError.accountUnavailable
        }
        try await subscriptionCredentialVault.setEnabled(enabled, for: accountID)
        try await refreshNativeSubscriptionAccounts()
        await reconcileGatewayAfterCredentialChange()
    }

    private func pollNativeSubscriptionLogin(_ loginID: UUID) async {
        while !Task.isCancelled {
            guard let login = await subscriptionOAuthLoginCoordinator.status(loginID) else { return }
            switch login.state {
            case .waiting:
                try? await Task.sleep(for: .milliseconds(500))
            case .completed:
                do {
                    try await refreshNativeSubscriptionAccounts()
                    try await refreshNativeSubscriptionModels()
                    await reconcileGatewayAfterCredentialChange()
                    snapshot.subscriptions.errorMessage = nil
                } catch {
                    snapshot.subscriptions.errorMessage = error.localizedDescription
                }
                snapshot.subscriptions.activeLogin = nil
                snapshot.subscriptions.activeProvider = nil
                emit()
                subscriptionOAuthLoginTask = nil
                return
            case let .failed(message):
                snapshot.subscriptions.errorMessage = message
                snapshot.subscriptions.activeLogin = nil
                snapshot.subscriptions.activeProvider = nil
                emit()
                subscriptionOAuthLoginTask = nil
                return
            case .cancelled:
                snapshot.subscriptions.activeLogin = nil
                snapshot.subscriptions.activeProvider = nil
                emit()
                subscriptionOAuthLoginTask = nil
                return
            }
        }
    }

    private func refreshNativeSubscriptionAccounts() async throws {
        snapshot.subscriptions.accounts = try await subscriptionCredentialVault.accounts().map { account in
            SubscriptionAccount(
                id: account.id.uuidString,
                name: account.user,
                provider: account.provider.rawValue,
                disabled: !account.enabled,
                email: account.user,
                accountType: account.plan
            )
        }
        if !snapshot.subscriptions.accounts.isEmpty,
           !snapshot.configuration.endpoints.contains(where: { $0.id == APIEndpointConfiguration.nativeSubscriptionEndpointID }) {
            var candidate = snapshot.configuration
            candidate.endpoints.append(.modelMoorSubscription())
            try await saveConfiguration(candidate)
        }
        emit()
    }

    func refreshNativeSubscriptionModels() async throws {
        let accounts = try await subscriptionCredentialVault.accounts().filter(\.enabled)
        var discovered: [RemoteModelMetadata] = []
        if let account = accounts.first(where: { $0.provider == .codex }) {
            let credential = try await subscriptionCredentialVault.usableCredential(
                for: account.id,
                using: subscriptionOAuthClient
            )
            let codexModels = try await CodexSubscriptionAPIAdapter().models(using: credential)
            discovered += codexModels.map { RemoteModelMetadata(id: $0.id, object: "model", ownedBy: "openai") }
        }
        if accounts.contains(where: { $0.provider == .claude }) {
            discovered += ClaudeCodeSubscriptionAPIAdapter.models.map {
                RemoteModelMetadata(id: $0.id, object: "model", ownedBy: "anthropic")
            }
        }
        if accounts.contains(where: { $0.provider == .xai }) {
            discovered += GrokBuildSubscriptionAPIAdapter.models.map {
                RemoteModelMetadata(id: $0.id, object: "model", ownedBy: "xai")
            }
        }
        if accounts.contains(where: { $0.provider == .kimi }) {
            discovered += KimiCodeSubscriptionAPIAdapter.models.map {
                RemoteModelMetadata(id: $0, object: "model", ownedBy: "moonshotai")
            }
        }
        let endpointID = APIEndpointConfiguration.nativeSubscriptionEndpointID
        snapshot.inspections[endpointID] = EndpointInspection(
            endpointID: endpointID,
            url: URL(string: "modelmoor://subscriptions/models")!,
            checkedAt: Date(),
            statusCode: accounts.isEmpty ? nil : 200,
            contentType: "application/json",
            models: discovered,
            classification: .llmAPI
        )
        emit()
    }

    func reconcileManagedSubscriptions() async {
        try? await refreshNativeSubscriptionAccounts()
    }
}
