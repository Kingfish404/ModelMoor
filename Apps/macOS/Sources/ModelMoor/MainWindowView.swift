import ModelMoorApplication
import ModelMoorCore
import ModelMoorSystem
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var lifecycle: AppLifecycleController
    @EnvironmentObject private var dirtyDrafts: DirtyDraftCoordinator
    @State private var selection: NavigationSelection? = .overview
    @State private var showsAddEndpoint = false
    @State private var showsAddSSHConnection = false
    @State private var showsAddModels = false

    var body: some View {
        NavigationSplitView {
            ModelMoorSidebar(
                selection: guardedSelection,
                addEndpoint: { showsAddEndpoint = true },
                addSSHConnection: { showsAddSSHConnection = true }
            )
                .environmentObject(model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detailPane
        }
        .frame(minWidth: 860, minHeight: 600)
        .toolbar { toolbar }
        .sheet(isPresented: $showsAddEndpoint) {
            AddEndpointFlow()
                .environmentObject(model)
        }
        .sheet(isPresented: $showsAddSSHConnection) {
            AddSSHConnectionSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $showsAddModels) {
            AddUnifiedModelsSheet()
                .environmentObject(model)
        }
        .alert(
            "Apply Changes Before Continuing?",
            isPresented: dirtyDraftPromptPresented,
            presenting: dirtyDrafts.prompt
        ) { _ in
            Button("Apply Changes") {
                dirtyDrafts.applyAndProceed()
            }
            Button("Discard Changes", role: .destructive) {
                dirtyDrafts.discardAndProceed()
            }
            Button("Cancel", role: .cancel) {
                dirtyDrafts.cancelPendingTransition()
            }
        } message: { prompt in
            Text("\(prompt.title) has unapplied changes. Apply them before leaving this view?")
        }
        .onChange(of: selection) { _, value in
            synchronizeSelection(value)
        }
        .onChange(of: model.navigationRequest) { _, value in
            guard let value else { return }
            model.navigationRequest = nil
            requestSelection(value)
        }
        .onChange(of: model.addEndpointRequest) { _, _ in
            showsAddEndpoint = true
        }
        .onChange(of: model.addSSHConnectionRequest) { _, _ in
            showsAddSSHConnection = true
        }
        .onAppear {
            if let request = model.navigationRequest {
                model.navigationRequest = nil
                requestSelection(request)
            }
            synchronizeSelection(selection)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        VStack(spacing: 0) {
            if let errorMessage = model.errorMessage {
                ErrorBanner(message: errorMessage, dismiss: model.dismissError)
                Divider()
            }

            if model.isLoaded {
                selectedDetail
            } else {
                ProgressView("Loading ModelMoor…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading ModelMoor configuration")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var selectedDetail: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewView(addEndpoint: { showsAddEndpoint = true }, selection: guardedSelection)
                .environmentObject(model)
        case let .endpoint(id):
            EndpointDetailView(endpointID: id, manageModels: { showsAddModels = true })
                .environmentObject(model)
                .environmentObject(dirtyDrafts)
        case .subscriptionAccounts:
            SubscriptionAccountsView(configureModels: showSubscriptionModels)
                .environmentObject(model)
        case .gateway:
            GatewayDetailView(addEndpoint: { showsAddEndpoint = true }, addModels: { showsAddModels = true })
                .environmentObject(model)
        case .usage:
            UsageDetailView()
                .environmentObject(model)
        case .settings:
            GeneralSettingsView()
                .environmentObject(model)
        case let .connection(id):
            SSHConnectionDetailView(connectionID: id, selection: guardedSelection)
                .environmentObject(model)
                .environmentObject(dirtyDrafts)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: lifecycle.toggleSidebar) {
                Label("Show or hide sidebar", systemImage: "sidebar.left")
            }
            .help("Show or hide the sidebar")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            switch selection ?? .overview {
            case let .endpoint(id):
                let endpoint = model.configuration.endpoints.first { $0.id == id }
                let resolvedURL = endpoint.flatMap { model.endpointURL($0) }
                Button {
                    guard let resolvedURL else { return }
                    model.copy(resolvedURL.absoluteString)
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
                .disabled(!EndpointInteractionPolicy.canCopyURL(resolvedURL))
                Button { Task { await model.inspectEndpoint(id) } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(endpoint.map {
                    !EndpointInteractionPolicy.canRefresh(
                        $0,
                        inspectingEndpointIDs: model.inspectingEndpointIDs
                    )
                } ?? true)
            case .gateway:
                Button(action: model.copyGatewayURL) {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
                Button { showsAddModels = true } label: {
                    Label("Add models", systemImage: "plus")
                }
                .disabled(!model.configuration.endpoints.contains { $0.enabled && $0.kind == .openAICompatible })
            case .subscriptionAccounts:
                Button {
                    Task { await model.refreshSubscriptionAccountState() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshingSubscriptionAccounts)
                Button(action: showSubscriptionModels) {
                    Label("Configure models", systemImage: "cube.transparent")
                }
                .disabled(subscriptionModelCount == 0)
            case let .connection(id):
                let phase = model.status(for: id).phase
                Button {
                    Task {
                        if phase.usesDisconnectAction { await model.disconnect(id) }
                        else { await model.connect(id) }
                    }
                } label: {
                    Label(
                        phase.connectionActionTitle,
                        systemImage: phase.usesDisconnectAction ? "stop.fill" : "play.fill"
                    )
                }
                .disabled(model.configuration.tunnels.first(where: { $0.id == id }).map {
                    !ConnectionInteractionPolicy.canPerformPrimaryAction($0, phase: phase)
                } ?? true)
                Button { Task { await model.inspectMappings(in: id) } } label: {
                    Label("Run diagnostics", systemImage: "stethoscope")
                }
            case .overview:
                Button {
                    Task { await model.inspectAllEndpoints() }
                } label: {
                    Label(
                        model.isInspectingAllEndpoints ? "Refreshing…" : "Refresh Status",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(!canRefreshAllEndpoints)
                .help(model.isInspectingAllEndpoints ? "Refreshing endpoint status" : "Refresh all endpoint status")
                .accessibilityLabel("Refresh all endpoint status")
                .accessibilityValue(model.isInspectingAllEndpoints ? "In progress" : "Ready")
            case .usage, .settings:
                EmptyView()
            }
        }
    }

    private func synchronizeSelection(_ selection: NavigationSelection?) {
        switch selection {
        case let .endpoint(id):
            model.selectedEndpointID = id
            model.selectedTunnelID = nil
        case let .connection(id):
            model.selectedEndpointID = nil
            model.selectedTunnelID = id
        case .overview, .subscriptionAccounts, .gateway, .usage, .settings, nil:
            model.selectedEndpointID = nil
            model.selectedTunnelID = nil
        }
    }

    private var canRefreshAllEndpoints: Bool {
        EndpointInteractionPolicy.canRefreshAll(
            endpoints: model.configuration.endpoints,
            inspectingEndpointIDs: model.inspectingEndpointIDs
        )
    }

    private var guardedSelection: Binding<NavigationSelection?> {
        Binding(
            get: { selection },
            set: { requestedSelection in requestSelection(requestedSelection) }
        )
    }

    private var dirtyDraftPromptPresented: Binding<Bool> {
        Binding(
            get: { dirtyDrafts.prompt != nil },
            set: { presented in
                if !presented { dirtyDrafts.cancelPendingTransition() }
            }
        )
    }

    private func requestSelection(_ requestedSelection: NavigationSelection?) {
        guard requestedSelection != selection else { return }
        dirtyDrafts.requestTransition {
            selection = requestedSelection
        }
    }

    private var subscriptionModelCount: Int {
        model.inspections[model.configuration.cliProxy.endpointID]?.models?.count ?? 0
    }

    private func showSubscriptionModels() {
        model.preferredModelEndpointID = model.configuration.cliProxy.endpointID
        showsAddModels = true
    }

}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    @AccessibilityFocusState private var messageIsFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityFocused($messageIsFocused)
            Button("Dismiss", action: dismiss)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
        .onAppear { messageIsFocused = true }
        .onChange(of: message) { _, _ in messageIsFocused = true }
    }
}
