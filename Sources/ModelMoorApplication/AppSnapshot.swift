import Foundation
import ModelMoorCore
import ModelMoorGateway
import ModelMoorSystem

/// Whether the current process drives tunnels/Gateway, and who owns the
/// runtime otherwise. Secrets never appear in snapshots.
public enum SessionRuntimeState: Equatable, Sendable {
    /// This process has not acquired the runtime owner lock.
    case stopped
    /// This process owns the runtime (tunnels/Gateway may still be starting).
    case running
    /// Another ModelMoor process (GUI, `modelmoor run`, TUI) owns the runtime.
    case ownedExternally(owner: String?)
}

/// Secret-free managed subscription state shared by every presentation.
/// Login URLs and device codes are short-lived interaction data; credentials
/// and management passwords never enter this snapshot.
public struct ManagedSubscriptionSnapshot: Equatable, Sendable {
    public var runtimeState: CLIProxyRuntimeState
    public var accounts: [CLIProxyAccount]
    public var activeLogin: CLIProxyLoginSession?
    public var activeProvider: CLIProxyLoginProvider?
    public var isRefreshingAccounts: Bool
    public var updatingAccountIDs: Set<String>
    public var usage: [String: SubscriptionUsageSnapshot]
    public var isRefreshingUsage: Bool
    public var isUsageProviderAvailable: Bool
    public var errorMessage: String?

    public init(
        runtimeState: CLIProxyRuntimeState = .stopped,
        accounts: [CLIProxyAccount] = [],
        activeLogin: CLIProxyLoginSession? = nil,
        activeProvider: CLIProxyLoginProvider? = nil,
        isRefreshingAccounts: Bool = false,
        updatingAccountIDs: Set<String> = [],
        usage: [String: SubscriptionUsageSnapshot] = [:],
        isRefreshingUsage: Bool = false,
        isUsageProviderAvailable: Bool = false,
        errorMessage: String? = nil
    ) {
        self.runtimeState = runtimeState
        self.accounts = accounts
        self.activeLogin = activeLogin
        self.activeProvider = activeProvider
        self.isRefreshingAccounts = isRefreshingAccounts
        self.updatingAccountIDs = updatingAccountIDs
        self.usage = usage
        self.isRefreshingUsage = isRefreshingUsage
        self.isUsageProviderAvailable = isUsageProviderAvailable
        self.errorMessage = errorMessage
    }
}

/// Immutable, secret-free projection of everything a presentation layer
/// (macOS GUI, `modelmoor` CLI, `modelmoor-tui`) may render. Business state
/// changes only through `ModelMoorSession` commands; views subscribe to
/// `snapshots()` instead of touching services directly.
public struct AppSnapshot: Equatable, Sendable {
    public var configuration: ModelMoorConfiguration
    public var tunnelStatuses: [UUID: TunnelStatus]
    public var gatewayState: GatewayServiceState
    public var inspections: [UUID: EndpointInspection]
    public var usage: TokenUsageSnapshot
    public var requestedTunnelIDs: Set<UUID>
    public var runtimeState: SessionRuntimeState
    public var subscriptions: ManagedSubscriptionSnapshot
    /// SSH config aliases are presentation-safe discovery metadata. The
    /// source path is never included in diagnostics and credentials are not
    /// read while scanning.
    public var sshTargets: [SSHHostTarget]
    public var isRefreshingSSHTargets: Bool
    /// IDs only: lets synchronous presentation code render credential state
    /// without touching Keychain/Secret Service on the UI thread.
    public var availableEndpointAPIKeyIDs: Set<UUID>
    public var isLoaded: Bool

    public init(
        configuration: ModelMoorConfiguration = ModelMoorConfiguration(),
        tunnelStatuses: [UUID: TunnelStatus] = [:],
        gatewayState: GatewayServiceState = .stopped,
        inspections: [UUID: EndpointInspection] = [:],
        usage: TokenUsageSnapshot = .zero,
        requestedTunnelIDs: Set<UUID> = [],
        runtimeState: SessionRuntimeState = .stopped,
        subscriptions: ManagedSubscriptionSnapshot = ManagedSubscriptionSnapshot(),
        sshTargets: [SSHHostTarget] = [],
        isRefreshingSSHTargets: Bool = false,
        availableEndpointAPIKeyIDs: Set<UUID> = [],
        isLoaded: Bool = false
    ) {
        self.configuration = configuration
        self.tunnelStatuses = tunnelStatuses
        self.gatewayState = gatewayState
        self.inspections = inspections
        self.usage = usage
        self.requestedTunnelIDs = requestedTunnelIDs
        self.runtimeState = runtimeState
        self.subscriptions = subscriptions
        self.sshTargets = sshTargets
        self.isRefreshingSSHTargets = isRefreshingSSHTargets
        self.availableEndpointAPIKeyIDs = availableEndpointAPIKeyIDs
        self.isLoaded = isLoaded
    }

    public func tunnelStatus(for id: UUID) -> TunnelStatus {
        tunnelStatuses[id] ?? TunnelStatus(tunnelID: id, phase: .stopped, message: "Stopped")
    }
}

/// A prepared, terminal-safe multi-field search query shared by presentation
/// layers. Parse once per filtering pass, then reuse it for every row.
public struct PresentationSearchQuery: Equatable, Sendable {
    public let normalizedText: String
    private let terms: [String]

    public init(_ text: String) {
        let safe = String(text.map { character in
            character.isASCII && (character < " " || character == "\u{7F}") ? " " : character
        })
        normalizedText = safe.trimmingCharacters(in: .whitespacesAndNewlines)
        terms = normalizedText.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// Every term may match a different visible field. Matching remains
    /// localized and case-insensitive so CJK and accented names behave like
    /// native macOS search rather than an ASCII-only command filter.
    public func matches(fields: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        return terms.allSatisfy { term in
            fields.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    /// Matches a document whose visible fields were prepared once by a
    /// presentation index. Field separators cannot occur in a query term, so
    /// a match never crosses from the suffix of one field into the prefix of
    /// another while each term may still match a different field.
    public func matches(document: PresentationSearchDocument) -> Bool {
        guard !terms.isEmpty else { return true }
        return terms.allSatisfy(document.text.localizedCaseInsensitiveContains)
    }
}

/// Precompiled searchable text for rows that are filtered repeatedly. The
/// unit-separator boundary is removed from user-provided fields and query
/// control characters are normalized to whitespace by PresentationSearchQuery.
public struct PresentationSearchDocument: Equatable, Sendable {
    fileprivate static let fieldSeparator = "\u{1F}"
    fileprivate let text: String

    public init(fields: [String]) {
        text = fields.map {
            $0.replacingOccurrences(of: Self.fieldSeparator, with: " ")
        }.joined(separator: Self.fieldSeparator)
    }
}
