import AppKit
import Foundation
import ModelMoorCore
import ModelMoorSystem
import SwiftUI

enum NavigationSelection: Hashable {
    case overview
    case endpoint(UUID)
    case subscriptionAccounts
    case gateway
    case usage
    case settings
    case connection(UUID)
}

/// Stable, menu-visible keyboard routes to the main destinations. Keeping the
/// mapping declarative makes menu titles, shortcuts and sidebar destinations
/// testable as one contract instead of duplicating them across command bodies.
struct MainNavigationCommand: Identifiable, Equatable {
    let titleKey: String
    let selection: NavigationSelection
    let shortcut: Character

    var id: NavigationSelection { selection }
    var localizedTitle: String { AppLocalization.string(titleKey) }
    var keyEquivalent: KeyEquivalent { KeyEquivalent(shortcut) }

    static let all: [MainNavigationCommand] = [
        MainNavigationCommand(titleKey: "Overview", selection: .overview, shortcut: "1"),
        MainNavigationCommand(titleKey: "Unified API", selection: .gateway, shortcut: "2"),
        MainNavigationCommand(titleKey: "Subscription", selection: .subscriptionAccounts, shortcut: "3"),
        MainNavigationCommand(titleKey: "Usage", selection: .usage, shortcut: "4"),
        MainNavigationCommand(titleKey: "Settings", selection: .settings, shortcut: "5")
    ]
}

/// Window-scoped request channel for moving keyboard focus into the native
/// sidebar search field. The monotonic revision preserves requests issued
/// before SwiftUI finishes mounting the main window and supports refocusing
/// an already-presented search interface.
@MainActor
final class SidebarSearchFocusCoordinator: ObservableObject {
    @Published private(set) var requestRevision = 0

    func requestFocus() {
        requestRevision &+= 1
    }
}

/// Connects an external focus request to a native `.searchable` field.
/// Kept separate from `ModelMoorSidebar` so the real AppKit focus path can be
/// exercised without constructing the business model in application tests.
struct SidebarSearchModifier: ViewModifier {
    @Binding var text: String
    @ObservedObject var coordinator: SidebarSearchFocusCoordinator
    @State private var searchIsPresented = false
    @State private var consumedRevision = 0

    func body(content: Content) -> some View {
        content
            .searchable(
                text: $text,
                isPresented: $searchIsPresented,
                placement: .sidebar,
                prompt: "Search connections and endpoints"
            )
            .background {
                SidebarSearchFocusBridge(
                    requestRevision: coordinator.requestRevision,
                    searchIsPresented: searchIsPresented
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            .onAppear(perform: consumePendingRequest)
            .onChange(of: coordinator.requestRevision) { _, _ in
                consumePendingRequest()
            }
    }

    private func consumePendingRequest() {
        guard coordinator.requestRevision != consumedRevision else { return }
        consumedRevision = coordinator.requestRevision
        // `isPresented` can remain true after keyboard focus moves elsewhere.
        // Briefly dismissing before the next main-loop turn makes a repeated
        // menu command restore focus as well as the first command.
        searchIsPresented = false
        DispatchQueue.main.async {
            searchIsPresented = true
        }
    }
}

/// macOS 14 presents `.searchable` programmatically but doesn't reliably
/// restore keyboard focus when a nonempty search field is already visible.
/// This zero-size bridge scopes the fallback to the containing window and
/// hands first responder to SwiftUI's native `NSSearchField` after presentation.
private struct SidebarSearchFocusBridge: NSViewRepresentable {
    let requestRevision: Int
    let searchIsPresented: Bool

    private enum FocusRetry {
        static let timeout: TimeInterval = 4
        static let interval: TimeInterval = 0.01
    }

    final class Coordinator {
        var focusedRevision = 0
        var pendingRevision = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard requestRevision != 0 else { return }
        guard searchIsPresented else {
            if context.coordinator.pendingRevision == requestRevision {
                context.coordinator.pendingRevision = 0
            }
            return
        }
        guard requestRevision != context.coordinator.focusedRevision,
              requestRevision != context.coordinator.pendingRevision else { return }

        context.coordinator.pendingRevision = requestRevision
        let deadline = DispatchTime.now() + FocusRetry.timeout
        DispatchQueue.main.async {
            focusSearchField(
                in: nsView,
                requestRevision: requestRevision,
                coordinator: context.coordinator,
                deadline: deadline
            )
        }
    }

    private func focusSearchField(
        in nsView: NSView,
        requestRevision: Int,
        coordinator: Coordinator,
        deadline: DispatchTime
    ) {
        guard coordinator.pendingRevision == requestRevision else { return }

        if let window = nsView.window,
           let searchField = searchField(in: window),
           window.makeFirstResponder(searchField) {
            coordinator.focusedRevision = requestRevision
            coordinator.pendingRevision = 0
            return
        }

        guard DispatchTime.now() < deadline else {
            coordinator.pendingRevision = 0
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + FocusRetry.interval) {
            focusSearchField(
                in: nsView,
                requestRevision: requestRevision,
                coordinator: coordinator,
                deadline: deadline
            )
        }
    }

    private func searchField(in window: NSWindow) -> NSSearchField? {
        if let contentView = window.contentView,
           let field = searchField(in: contentView) {
            return field
        }
        for item in window.toolbar?.items ?? [] {
            if let view = item.view,
               let field = searchField(in: view) {
                return field
            }
        }
        return nil
    }

    private func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for child in view.subviews {
            if let field = searchField(in: child) { return field }
        }
        return nil
    }
}

/// Usage aggregation feeds visible sidebar/overview values but does not need
/// to wake the disk while the app is backgrounded or its only window is
/// minimized. Reactivation performs an immediate refresh through AppModel.
enum PresentationRefreshPolicy {
    static func shouldRefreshUsage(
        windowIsVisible: Bool,
        windowIsMiniaturized: Bool,
        applicationIsActive: Bool
    ) -> Bool {
        windowIsVisible && !windowIsMiniaturized && applicationIsActive
    }
}

enum DirtyDraftID: Hashable {
    case endpoint(UUID)
    case connection(UUID)
}

struct DirtyDraftPrompt: Identifiable, Equatable {
    let draftID: DirtyDraftID
    let title: String

    var id: DirtyDraftID { draftID }
}

struct DirtyDraftResolution: Equatable {
    enum Kind: Equatable {
        case applied
        case discarded
    }

    let draftID: DirtyDraftID
    let kind: Kind
    let revision: Int
}

/// Coordinates navigation and application lifecycle transitions with the
/// currently visible editor. Detail views remain the owners of their drafts;
/// this object owns only the transition contract around them.
@MainActor
final class DirtyDraftCoordinator: ObservableObject {
    typealias ApplyAction = @MainActor () async -> Bool
    typealias TransitionAction = @MainActor () -> Void

    @Published private(set) var prompt: DirtyDraftPrompt?
    @Published private(set) var resolution: DirtyDraftResolution?
    @Published private(set) var isApplying = false

    private struct Registration {
        let id: DirtyDraftID
        let title: String
        var isDirty: Bool
        let apply: ApplyAction
    }

    private var registration: Registration?
    private var pendingTransition: TransitionAction?
    private var resolutionRevision = 0

    var hasUnsavedChanges: Bool { registration?.isDirty == true }

    func register(
        id: DirtyDraftID,
        title: String,
        isDirty: Bool,
        apply: @escaping ApplyAction
    ) {
        guard !isApplying else { return }
        registration = Registration(id: id, title: title, isDirty: isDirty, apply: apply)
    }

    func unregister(id: DirtyDraftID) {
        guard registration?.id == id, pendingTransition == nil, !isApplying else { return }
        registration = nil
    }

    func abandon(id: DirtyDraftID) {
        guard registration?.id == id else { return }
        registration = nil
        prompt = nil
        pendingTransition = nil
    }

    func requestTransition(_ action: @escaping TransitionAction) {
        guard !isApplying else { return }
        guard let registration, registration.isDirty else {
            action()
            return
        }
        pendingTransition = action
        prompt = DirtyDraftPrompt(draftID: registration.id, title: registration.title)
    }

    func cancelPendingTransition() {
        guard !isApplying else { return }
        prompt = nil
        pendingTransition = nil
    }

    func discardAndProceed() {
        guard let registration, registration.isDirty else {
            proceed()
            return
        }
        self.registration?.isDirty = false
        publishResolution(for: registration.id, kind: .discarded)
        prompt = nil
        proceed()
    }

    @discardableResult
    func applyAndProceed() -> Task<Void, Never>? {
        guard let registration, registration.isDirty, !isApplying else {
            proceed()
            return nil
        }
        prompt = nil
        isApplying = true
        return Task { @MainActor [weak self] in
            let succeeded = await registration.apply()
            guard let self else { return }
            self.isApplying = false
            guard succeeded else {
                self.pendingTransition = nil
                return
            }
            if self.registration?.id == registration.id {
                self.registration?.isDirty = false
            }
            self.publishResolution(for: registration.id, kind: .applied)
            self.proceed()
        }
    }

    private func proceed() {
        let action = pendingTransition
        pendingTransition = nil
        prompt = nil
        action?()
    }

    private func publishResolution(for id: DirtyDraftID, kind: DirtyDraftResolution.Kind) {
        resolutionRevision += 1
        resolution = DirtyDraftResolution(draftID: id, kind: kind, revision: resolutionRevision)
    }
}

/// Bridges the draft decision state machine to AppKit's two-pass window-close
/// contract. The first close is vetoed while SwiftUI presents Apply/Discard/
/// Cancel; a successful decision authorizes exactly one subsequent
/// `performClose`, then immediately returns to protected mode.
@MainActor
final class DirtyWindowCloseCoordinator {
    private let dirtyDrafts: DirtyDraftCoordinator
    private var closeApproved = false

    init(dirtyDrafts: DirtyDraftCoordinator) {
        self.dirtyDrafts = dirtyDrafts
    }

    func shouldClose(_ window: NSWindow) -> Bool {
        if closeApproved {
            closeApproved = false
            return true
        }
        guard dirtyDrafts.hasUnsavedChanges else { return true }
        dirtyDrafts.requestTransition { [weak self, weak window] in
            guard let self, let window else { return }
            self.closeApproved = true
            window.performClose(nil)
        }
        return false
    }
}

enum EndpointSourceChoice: String, CaseIterable, Identifiable {
    case ssh
    case direct

    var id: Self { self }
}

enum EndpointPreset: String, CaseIterable, Identifiable {
    case deepSeek
    case openAI
    case ollama
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .openAI: "OpenAI-compatible"
        case .ollama: "Ollama"
        case .custom: "Custom HTTP"
        }
    }
}

enum EndpointReadiness {
    case disabled
    case unknown
    case checking
    case ready(Int)
    case needsAttention(String)

    var title: String {
        switch self {
        case .disabled: AppLocalization.string("Disabled")
        case .unknown: AppLocalization.string("Not checked")
        case .checking: AppLocalization.string("Checking")
        case let .ready(count): String.localizedStringWithFormat(
            AppLocalization.string(count == 1 ? "Ready, %lld model" : "Ready, %lld models"),
            Int64(count)
        )
        case let .needsAttention(message): message
        }
    }

    var symbol: String {
        switch self {
        case .disabled: "circle"
        case .unknown: "questionmark.circle"
        case .checking: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }
}

extension TunnelPhase {
    var usesDisconnectAction: Bool {
        switch self {
        case .waitingForNetwork, .connecting, .connected, .waitingToRetry:
            true
        case .stopped, .disconnecting, .failed:
            false
        }
    }

    var connectionActionTitle: String {
        switch self {
        case .stopped: AppLocalization.string("Connect")
        case .waitingForNetwork, .connected, .waitingToRetry: AppLocalization.string("Disconnect")
        case .connecting: AppLocalization.string("Cancel Connection")
        case .disconnecting: AppLocalization.string("Disconnecting…")
        case .failed: AppLocalization.string("Retry")
        }
    }

}
