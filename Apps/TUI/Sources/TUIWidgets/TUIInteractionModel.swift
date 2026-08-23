import Foundation
import ModelMoorApplication
import ModelMoorCore

/// Terminal-independent interaction model shared by the interactive TUI and
/// its tests. Keeping pane order and action availability here prevents the
/// visible key guide from drifting away from the implemented shortcuts.
public enum TUIPane: Int, CaseIterable, Hashable, Sendable {
    case help
    case overview
    case unifiedAPI
    case sshConnections
    case apiEndpoints
    case subscriptions
    case needsAttention
    case settings

    public var title: String {
        switch self {
        case .help: "Help"
        case .overview: "Overview"
        case .unifiedAPI: "Unified API"
        case .sshConnections: "SSH Connections"
        case .apiEndpoints: "API Endpoints"
        case .subscriptions: "Subscriptions"
        case .needsAttention: "Needs Attention"
        case .settings: "Settings"
        }
    }

    public var tabTitle: String { "\(rawValue) \(title)" }

    public var actions: [TUIAction] {
        // Content panes are intentionally browse-only. The bottom `moor>`
        // shell is the sole place that accepts commands or editable text.
        []
    }

    public static func matching(shortcut: Character) -> TUIPane? {
        guard let value = shortcut.wholeNumberValue else { return nil }
        return TUIPane(rawValue: value)
    }
}

public enum TUIAction: String, Equatable, Sendable {
    case filterList
    case clearFilter
    case connectOrDisconnect
    case retry
    case copyURL
    case copyModel
    case addSSH
    case addAPI
    case configureSubscriptions
    case configureGateway
}

public struct TUIConnectionActionAvailability: Equatable, Sendable {
    public var canToggleDesiredState: Bool
    public var canRetry: Bool

    public init(
        tunnel: TunnelConfiguration,
        phase: TunnelPhase,
        isRequested: Bool
    ) {
        canToggleDesiredState = ConnectionInteractionPolicy.canToggleDesiredState(
            tunnel,
            phase: phase,
            isRequested: isRequested
        )
        canRetry = ConnectionInteractionPolicy.canRetry(tunnel, phase: phase)
    }

    public init(canToggleDesiredState: Bool, canRetry: Bool) {
        self.canToggleDesiredState = canToggleDesiredState
        self.canRetry = canRetry
    }

    public static let unavailable = Self(
        canToggleDesiredState: false,
        canRetry: false
    )
}

public enum TUIRefreshRequestDecision: Equatable, Sendable {
    case start(reloadConfiguration: Bool)
    case queued
    case alreadyQueued
    case ignored
}

public enum TUIRefreshCompletionDecision: Equatable, Sendable {
    case continueRefresh(reloadConfiguration: Bool)
    case finish
}

/// Bounds repeated refresh input to the active run plus at most one trailing
/// run. A queued request never loses the stronger configuration-reload intent,
/// while cancellation prevents a finishing run from starting more work.
public struct TUIRefreshCoalescer: Equatable, Sendable {
    public private(set) var isRefreshing = false
    public private(set) var hasQueuedRefresh = false
    private var queuedReloadConfiguration = false
    private var acceptsRequests = true

    public init() {}

    public mutating func request(
        reloadConfiguration: Bool
    ) -> TUIRefreshRequestDecision {
        guard acceptsRequests else { return .ignored }
        guard isRefreshing else {
            isRefreshing = true
            return .start(reloadConfiguration: reloadConfiguration)
        }

        let wasQueued = hasQueuedRefresh
        hasQueuedRefresh = true
        queuedReloadConfiguration = queuedReloadConfiguration || reloadConfiguration
        return wasQueued ? .alreadyQueued : .queued
    }

    public mutating func completeCycle() -> TUIRefreshCompletionDecision {
        guard acceptsRequests, hasQueuedRefresh else {
            isRefreshing = false
            hasQueuedRefresh = false
            queuedReloadConfiguration = false
            return .finish
        }

        let reloadConfiguration = queuedReloadConfiguration
        hasQueuedRefresh = false
        queuedReloadConfiguration = false
        return .continueRefresh(reloadConfiguration: reloadConfiguration)
    }

    public mutating func cancel() {
        acceptsRequests = false
        isRefreshing = false
        hasQueuedRefresh = false
        queuedReloadConfiguration = false
    }
}

public enum TUIInteractionModel {
    public static let helpText = helpText(ascii: false)

    /// Returns only actions that have a valid target in the current frame.
    /// Filtering remains available for empty lists, while commands that act
    /// on a row disappear when the list has no visible selection. The Unified
    /// API URL is pane-scoped, so it remains copyable without a model route.
    public static func availableActions(
        for pane: TUIPane,
        hasVisibleSelection: Bool,
        hasActiveFilter: Bool,
        connectionActions: TUIConnectionActionAvailability = .unavailable,
        endpointCanCopyURL: Bool = false
    ) -> [TUIAction] {
        // Selection is view state only. All operations enter through the
        // shell, rather than contextual hotkeys in the content area.
        _ = (pane, hasVisibleSelection, hasActiveFilter, connectionActions, endpointCanCopyURL)
        return []
    }

    public static func helpText(ascii: Bool) -> String {
        _ = ascii
        return """
    Focus
      Tab       Move focus between tabs, content, and the shell
      mouse     Select tabs and list rows
      left/right Switch tabs while the tab row is focused
      up/down   Move through SSH connections or endpoints

    Shell
      :         Focus the moor> command line
      help      Open the Help pane
      refresh   Reload configuration and runtime status
      filter    Filter the current list; clear-filter removes it
      add ...   Add SSH, ports, or direct API endpoints
      subs
                Configure sign-in and proxy settings
      subs login <provider>
                Sign in; accounts, refresh, and cancel manage subscriptions
      gateway   Configure the Unified API
      connect, disconnect
                Change the selected or named SSH connection

    General
      ? or F1   Open the Help pane
      q         Quit safely

    Pane text is read-only. Click or Tab to focus text, then use Control-Space
    with arrows to select. Control-C or Alt-W copies the selection. Enter
    commands only in moor>. A focused list copies its selected row with Control-C.
    Subscriptions are available in pane 5. Settings are available in pane 7.
    Secrets are stored in the system keychain.
    """
    }

    /// Complete, static content for the first tab. Keep both the navigation
    /// reference and the detailed shell grammar together so help never needs
    /// to interrupt the terminal with a modal dialog.
    public static func helpPageText(ascii: Bool) -> String {
        "ModelMoor Help\n\n"
            + helpText(ascii: ascii)
            + "\n\n"
            + TUIShellParser.helpText
    }
}

/// Prevents hidden panes from initiating work that does not contribute to the
/// current terminal frame. Kept outside TermKit so the policy is testable in
/// ordinary CI without allocating a terminal.
public enum TUIVisibilityWorkPolicy {
    public static func shouldLoadDiagnostics(selectedPane: TUIPane) -> Bool {
        selectedPane == .needsAttention
    }

    public static func shouldRefreshUsage(selectedPane: TUIPane) -> Bool {
        selectedPane == .overview
    }

    /// Endpoint probes can be slow for remote services. Perform them only
    /// when their results are visible, rather than on every global refresh.
    public static func shouldInspectEndpoints(selectedPane: TUIPane) -> Bool {
        selectedPane == .apiEndpoints
    }
}

/// Reuses prepared multi-field search documents until their exact source
/// changes. TUI status snapshots may rebuild visible rows without changing
/// configuration, and filter edits must not reconstruct the same field text.
public struct TUISearchDocumentCache<Source: Equatable & Sendable>: Sendable {
    private var source: Source?
    public private(set) var documents: [PresentationSearchDocument] = []
    public private(set) var buildCount = 0

    public init() {}

    public mutating func prepare(
        for source: Source,
        build: (Source) -> [PresentationSearchDocument]
    ) -> [PresentationSearchDocument] {
        if self.source != source {
            documents = build(source)
            self.source = source
            buildCount += 1
        }
        return documents
    }
}

/// Preserves the identity the user selected independently from the row that a
/// filtered list temporarily highlights as a visible fallback. Snapshot ticks
/// may rebuild lists frequently; they must not turn that fallback into a new
/// command target unless the user actually moves the selection.
public struct TUISelectionMemory<ID: Hashable & Sendable>: Equatable, Sendable {
    public private(set) var preferredID: ID?

    public init(preferredID: ID? = nil) {
        self.preferredID = preferredID
    }

    public mutating func recordVisibleSelection(index: Int, visibleIDs: [ID]) {
        guard visibleIDs.indices.contains(index) else { return }
        preferredID = visibleIDs[index]
    }

    /// Returns the row to highlight after a render. If filtering merely hides
    /// the preferred identity, the memory is retained so clearing the filter
    /// restores it. If the item was deleted from the full data set, the
    /// clamped fallback becomes the new stable selection.
    public mutating func resolvedIndex(
        visibleIDs: [ID],
        allIDs: [ID],
        fallbackIndex: Int
    ) -> Int? {
        if let preferredID,
           let preferredIndex = visibleIDs.firstIndex(of: preferredID) {
            return preferredIndex
        }

        guard !visibleIDs.isEmpty else {
            if let preferredID, !allIDs.contains(preferredID) {
                self.preferredID = nil
            }
            return nil
        }

        let fallback = min(max(fallbackIndex, 0), visibleIDs.count - 1)
        if let preferredID {
            if !allIDs.contains(preferredID) {
                self.preferredID = visibleIDs[fallback]
            }
        } else {
            preferredID = visibleIDs[fallback]
        }
        return fallback
    }
}

public struct TUIRenderSections: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let summary = Self(rawValue: 1 << 0)
    public static let overview = Self(rawValue: 1 << 1)
    public static let tunnels = Self(rawValue: 1 << 2)
    public static let endpoints = Self(rawValue: 1 << 3)
    public static let gateway = Self(rawValue: 1 << 4)
    public static let attention = Self(rawValue: 1 << 5)
    public static let settings = Self(rawValue: 1 << 6)
    public static let subscriptions = Self(rawValue: 1 << 7)
    public static let all: Self = [summary, overview, tunnels, endpoints, gateway, attention, settings, subscriptions]
}

/// Maps snapshot deltas to the smallest set of panes that must be rebuilt.
/// Runtime and usage ticks can be frequent, so they must not allocate every
/// list row or re-read the diagnostic log when unrelated state changed.
public enum TUIRenderInvalidation {
    public static func sections(
        previous: AppSnapshot,
        next: AppSnapshot,
        force: Bool = false
    ) -> TUIRenderSections {
        if force { return .all }

        var result: TUIRenderSections = []
        if previous.configuration.tunnels != next.configuration.tunnels {
            result.formUnion([.summary, .overview, .tunnels, .attention, .settings])
        }
        if previous.configuration.endpoints != next.configuration.endpoints {
            result.formUnion([.summary, .overview, .endpoints, .gateway, .attention, .settings])
        }
        if previous.configuration.routes != next.configuration.routes {
            result.formUnion([.overview, .gateway, .settings])
        }
        if previous.configuration.gateway != next.configuration.gateway {
            result.formUnion([.overview, .gateway, .settings])
        }
        if previous.configuration.cliProxy != next.configuration.cliProxy {
            result.formUnion([.subscriptions, .settings])
        }
        if previous.runtimeState != next.runtimeState {
            result.formUnion([.summary, .attention])
        }
        if previous.gatewayState != next.gatewayState {
            result.formUnion([.summary, .overview, .gateway, .attention])
        }
        if previous.tunnelStatuses != next.tunnelStatuses
            || previous.requestedTunnelIDs != next.requestedTunnelIDs {
            result.formUnion([.overview, .tunnels, .attention])
        }
        if previous.inspections != next.inspections {
            result.formUnion([.endpoints, .attention])
        }
        if previous.availableEndpointAPIKeyIDs != next.availableEndpointAPIKeyIDs {
            result.formUnion([.endpoints, .attention])
        }
        if previous.usage != next.usage {
            result.insert(.overview)
        }
        if previous.subscriptions != next.subscriptions {
            result.formUnion([.subscriptions, .settings])
        }
        if previous.sshTargets != next.sshTargets
            || previous.isRefreshingSSHTargets != next.isRefreshingSSHTargets {
            result.insert(.settings)
        }
        if previous.isLoaded != next.isLoaded {
            result.insert(.summary)
        }
        return result
    }
}

public struct TUIGlyphSet: Equatable, Sendable {
    public var usesASCII: Bool
    public var active: String
    public var inactive: String
    public var pending: String
    public var failed: String
    public var requested: String
    public var info: String
    public var separator: String
    public var paneRange: String

    public static let ascii = Self(
        usesASCII: true,
        active: "*",
        inactive: "o",
        pending: "~",
        failed: "!",
        requested: ">",
        info: "i",
        separator: " | ",
        paneRange: "0-7"
    )

    /// Kept as an API-compatible alias for callers that previously requested
    /// Unicode glyphs. ModelMoor now uses ASCII in every terminal mode.
    public static let unicode = ascii

    public static func preferred(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        _ = environment
        return .ascii
    }
}
