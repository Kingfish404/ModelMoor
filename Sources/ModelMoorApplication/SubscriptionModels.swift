import Foundation

public enum SubscriptionProvider: String, CaseIterable, Codable, Equatable, Sendable {
    case codex
    case claude
    case kimi
    case xai

    public var displayName: String {
        switch self {
        case .codex: "ChatGPT / Codex"
        case .claude: "Claude Code"
        case .kimi: "Kimi Code"
        case .xai: "Grok Build"
        }
    }
}

public struct SubscriptionLoginSession: Equatable, Sendable {
    public var status: String
    public var url: URL
    public var state: String
    public var flow: String?
    public var userCode: String?
    public var expiresIn: Int?

    public init(
        status: String = "pending",
        url: URL,
        state: String,
        flow: String? = nil,
        userCode: String? = nil,
        expiresIn: Int? = 600
    ) {
        self.status = status
        self.url = url
        self.state = state
        self.flow = flow
        self.userCode = userCode
        self.expiresIn = expiresIn
    }
}

public struct SubscriptionAccount: Identifiable, Equatable, Sendable {
    public var id: String
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

    public init(
        id: String,
        name: String,
        provider: String,
        label: String? = nil,
        status: String? = nil,
        statusMessage: String? = nil,
        disabled: Bool = false,
        email: String? = nil,
        accountType: String? = nil,
        account: String? = nil,
        lastRefresh: String? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.label = label
        self.status = status
        self.statusMessage = statusMessage
        self.disabled = disabled
        self.email = email
        self.accountType = accountType
        self.account = account
        self.lastRefresh = lastRefresh
    }
}
