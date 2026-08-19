import ModelMoorCore
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var lifecycle: AppLifecycleController
    @State private var selection: NavigationSelection? = .overview
    @State private var showsAddEndpoint = false
    @State private var showsAddSSHConnection = false
    @State private var showsAddModels = false

    var body: some View {
        NavigationSplitView {
            ModelMoorSidebar(
                selection: $selection,
                addEndpoint: { showsAddEndpoint = true },
                addSSHConnection: { showsAddSSHConnection = true }
            )
                .environmentObject(model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
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
        .onChange(of: selection) { _, value in
            synchronizeSelection(value)
        }
        .onChange(of: model.navigationRequest) { _, value in
            guard let value else { return }
            selection = value
            model.navigationRequest = nil
        }
        .onChange(of: model.addEndpointRequest) { _, _ in
            showsAddEndpoint = true
        }
        .onChange(of: model.addSSHConnectionRequest) { _, _ in
            showsAddSSHConnection = true
        }
        .onAppear {
            if let request = model.navigationRequest {
                selection = request
                model.navigationRequest = nil
            }
            synchronizeSelection(selection)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewView(addEndpoint: { showsAddEndpoint = true }, selection: $selection)
                .environmentObject(model)
        case let .endpoint(id):
            EndpointDetailView(endpointID: id, manageModels: { showsAddModels = true })
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
            SSHConnectionDetailView(connectionID: id, selection: $selection)
                .environmentObject(model)
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
                Button {
                    guard let endpoint = model.configuration.endpoints.first(where: { $0.id == id }),
                          let url = model.endpointURL(endpoint) else { return }
                    model.copy(url.absoluteString)
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
                Button { Task { await model.inspectEndpoint(id) } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.inspectingEndpointIDs.contains(id))
            case .gateway:
                Button(action: model.copyGatewayURL) {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
                Button { showsAddModels = true } label: {
                    Label("Add models", systemImage: "plus")
                }
                .disabled(!model.configuration.endpoints.contains { $0.enabled && $0.kind == .openAICompatible })
            case let .connection(id):
                let phase = model.status(for: id).phase
                Button {
                    Task {
                        if phase == .connected { await model.disconnect(id) }
                        else { await model.connect(id) }
                    }
                } label: {
                    Label(phase == .connected ? "Disconnect" : "Connect", systemImage: phase == .connected ? "stop.fill" : "play.fill")
                }
                Button { Task { await model.inspectMappings(in: id) } } label: {
                    Label("Run diagnostics", systemImage: "stethoscope")
                }
            case .overview, .usage, .settings:
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
        case .overview, .gateway, .usage, .settings, nil:
            model.selectedEndpointID = nil
            model.selectedTunnelID = nil
        }
    }
}
