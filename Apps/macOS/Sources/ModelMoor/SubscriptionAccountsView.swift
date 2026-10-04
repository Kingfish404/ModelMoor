import ModelMoorCore
import ModelMoorApplication
import ModelMoorSystem
import SwiftUI

struct SubscriptionAccountsView: View {
    @EnvironmentObject private var model: AppModel
    let configureModels: () -> Void
    @State private var accountToDelete: SubscriptionAccount?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                accountPool
                connectAccounts
                unifiedAPIHandoff
                privacyNote
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(28)
        }
        .navigationTitle("Subscription")
        .refreshable {
            guard model.subscriptionActionAvailability.canRefreshAccounts else { return }
            await model.refreshSubscriptionAccountState()
        }
        .alert("Remove this subscription account?", isPresented: deletionAlertPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Account", role: .destructive) {
                guard let accountToDelete else { return }
                Task { await model.removeSubscriptionAccount(accountToDelete) }
            }
        } message: {
            Text("ModelMoor will remove the local OAuth credential for \(accountToDelete?.email ?? accountToDelete?.name ?? "this account").")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: headerSymbol)
                .font(.title2)
                .foregroundStyle(headerColor)
                .frame(width: 40, height: 40)
                .background(headerColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(headerTitle)
                    .font(.title2.weight(.semibold))
                Text(headerSubtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !model.subscriptionAccounts.isEmpty {
                Button {
                    Task { await model.refreshSubscriptionAccountState() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing || !model.subscriptionActionAvailability.canRefreshAccounts)
            }
        }
    }

    private var accountPool: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Account pool")
                    .font(.title2.weight(.semibold))
                if !model.subscriptionAccounts.isEmpty {
                    Text("\(enabledAccountCount) active of \(model.subscriptionAccounts.count)")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    if model.subscriptionAccounts.isEmpty {
                        ContentUnavailableView {
                            Label("No accounts connected", systemImage: "person.2.badge.plus")
                        } description: {
                            Text("Connect a supported provider below. You can add more than one account for each provider.")
                        }
                        .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        ForEach(Array(model.subscriptionAccounts.enumerated()), id: \.element.id) { index, account in
                            accountRow(account)
                            if index < model.subscriptionAccounts.count - 1 {
                                Divider().padding(.vertical, 7)
                            }
                        }
                    }
                }
                .padding(4)
            }
        }
    }

    private func accountRow(_ account: SubscriptionAccount) -> some View {
        HStack(spacing: 12) {
            Image(systemName: account.disabled ? "person.crop.circle.badge.xmark" : "person.crop.circle.badge.checkmark")
                .foregroundStyle(account.disabled ? Color.secondary : Color.green)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email ?? account.label ?? account.name)
                    .lineLimit(1)
                Text(accountSummary(account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let message = account.statusMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 16)
            if model.updatingSubscriptionAccountIDs.contains(account.id) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating \(account.email ?? account.name)")
            }
            Toggle("Use for routing", isOn: accountEnabledBinding(account))
                .toggleStyle(.switch)
                .fixedSize()
                .disabled(
                    model.updatingSubscriptionAccountIDs.contains(account.id)
                        || !model.subscriptionActionAvailability.canMutateAccounts
                )
            Menu {
                Button("Remove Account…", role: .destructive) {
                    accountToDelete = account
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More account actions")
            .accessibilityLabel("More actions for \(account.email ?? account.name)")
            .disabled(!model.subscriptionActionAvailability.canMutateAccounts)
        }
        .padding(.vertical, 3)
    }

    private var connectAccounts: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.subscriptionAccounts.isEmpty ? "Connect an account" : "Connect another account")
                    .font(.title2.weight(.semibold))
                Text("Each successful sign-in adds a separate credential to the account pool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(SubscriptionProvider.allCases.enumerated()), id: \.element) { index, provider in
                        providerRow(
                            provider: provider,
                            symbol: providerSymbol(provider),
                            description: providerDescription(provider)
                        )
                        if index < SubscriptionProvider.allCases.count - 1 {
                            Divider().padding(.vertical, 8)
                        }
                    }

                    if let login = model.activeSubscriptionLogin,
                       let provider = model.activeSubscriptionProvider {
                        Divider().padding(.vertical, 10)
                        loginProgress(login, provider: provider)
                    }
                }
                .padding(4)
            }
        }
    }

    private func providerRow(
        provider: SubscriptionProvider,
        symbol: String,
        description: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.body.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Button("Connect…") {
                Task { await model.connectSubscriptionAccount(provider) }
            }
            .disabled(!model.subscriptionActionAvailability.canStartLogin)
        }
        .padding(.vertical, 3)
    }

    private func loginProgress(
        _ login: SubscriptionLoginSession,
        provider: SubscriptionProvider
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text("Waiting for \(provider.displayName) sign-in")
                    .font(.body.weight(.medium))
                if let code = login.userCode {
                    HStack(spacing: 8) {
                        Text(code)
                            .font(.title3.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                        Button("Copy Code", action: model.copySubscriptionLoginCode)
                    }
                }
                Link("Open sign-in page", destination: login.url)
                    .font(.caption)
            }
            Spacer()
            Button("Cancel") {
                Task { await model.cancelSubscriptionLogin() }
            }
        }
    }

    private var unifiedAPIHandoff: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Models from subscriptions")
                    .font(.title2.weight(.semibold))
                Text("Choose which discovered models the Unified API should expose to clients.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                HStack(spacing: 12) {
                    Image(systemName: "cube.transparent")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subscriptionModelCount == 1 ? "1 model discovered" : "\(subscriptionModelCount) models discovered")
                            .font(.body.weight(.medium))
                        Text("API keys, public model names, and route configuration stay in Unified API.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Configure in Unified API…") {
                        model.preferredModelEndpointID = APIEndpointConfiguration.nativeSubscriptionEndpointID
                        configureModels()
                    }
                    .disabled(subscriptionModelCount == 0)
                }
                .padding(4)
            }
        }
    }

    private var privacyNote: some View {
        Text("Sign-in happens on the provider's site, and ModelMoor never receives your password. OAuth credentials are stored in ModelMoor's private secret store and are not written to local agent files.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var enabledAccountCount: Int {
        model.subscriptionAccounts.filter { !$0.disabled }.count
    }

    private var subscriptionModelCount: Int {
        model.inspections[APIEndpointConfiguration.nativeSubscriptionEndpointID]?.models?.count ?? 0
    }

    private var isRefreshing: Bool {
        model.isRefreshingSubscriptionAccounts
            || model.inspectingEndpointIDs.contains(APIEndpointConfiguration.nativeSubscriptionEndpointID)
    }

    private var headerTitle: String {
        if model.activeSubscriptionLogin != nil { return "Waiting for sign-in" }
        if model.subscriptionAccounts.isEmpty { return "Connect subscription accounts" }
        return enabledAccountCount == 1
            ? "1 account is active"
            : "\(enabledAccountCount) accounts are active"
    }

    private var headerSubtitle: String {
        if model.subscriptionAccounts.isEmpty {
            return "Add subscription accounts, then decide which accounts participate in routing."
        }
        return "Enabled accounts participate in local round-robin routing. Disabled accounts keep their sign-in but receive no requests."
    }

    private var headerSymbol: String {
        if model.activeSubscriptionLogin != nil { return "person.crop.circle.badge.clock" }
        return model.subscriptionAccounts.isEmpty ? "person.2.badge.plus" : "person.2.fill"
    }

    private var headerColor: Color {
        return enabledAccountCount > 0 ? .green : .secondary
    }

    private func accountEnabledBinding(_ account: SubscriptionAccount) -> Binding<Bool> {
        Binding(
            get: {
                !(model.subscriptionAccounts.first(where: { $0.id == account.id })?.disabled ?? account.disabled)
            },
            set: { enabled in
                Task { await model.setSubscriptionAccountEnabled(account, enabled: enabled) }
            }
        )
    }

    private func accountSummary(_ account: SubscriptionAccount) -> String {
        let provider = providerDisplayName(account.provider)
        let state = account.disabled ? "excluded from routing" : (account.status ?? "ready")
        return "\(provider) · \(state)"
    }

    private func providerDisplayName(_ provider: String) -> String {
        switch provider.lowercased() {
        case "codex": "ChatGPT / Codex"
        case "claude", "anthropic": "Claude Code"
        case "kimi": "Kimi Code"
        case "xai", "grok": "Grok Build"
        default: provider.capitalized
        }
    }

    private func providerSymbol(_ provider: SubscriptionProvider) -> String {
        switch provider {
        case .codex: "bubble.left.and.text.bubble.right"
        case .claude: "command"
        case .kimi: "moon.stars"
        case .xai: "sparkles"
        }
    }

    private func providerDescription(_ provider: SubscriptionProvider) -> String {
        switch provider {
        case .codex: "Use a ChatGPT subscription for Codex and compatible OpenAI models."
        case .claude: "Use a Claude subscription through the Claude Code OAuth flow."
        case .kimi: "Use a Kimi subscription through its device sign-in flow."
        case .xai: "Use Grok Build's device sign-in with a temporary, isolated profile."
        }
    }

    private var deletionAlertPresented: Binding<Bool> {
        Binding(
            get: { accountToDelete != nil },
            set: { if !$0 { accountToDelete = nil } }
        )
    }
}
