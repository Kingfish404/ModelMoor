import ModelMoorCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var lifecycle: AppLifecycleController
    @EnvironmentObject private var updates: UpdateController

    var body: some View {
        Label("ModelMoor, \(overallStatus)", systemImage: model.menuBarSymbol).disabled(true)

        if model.configuration.gateway.enabled { gatewayMenu }
        endpointMenu
        if !otherEndpoints.isEmpty { otherServicesMenu }
        connectionMenu
        if !attentionItems.isEmpty || model.errorMessage != nil { attentionMenu }

        Divider()
        Button {
            Task { await model.inspectAllEndpoints() }
        } label: {
            Label(model.inspectingEndpointIDs.isEmpty ? "Refresh Status" : "Refreshing Status…", systemImage: "arrow.clockwise")
        }
        .disabled(model.configuration.endpoints.isEmpty || !model.inspectingEndpointIDs.isEmpty)

        Button { lifecycle.showMainWindow() } label: {
            Label("Open ModelMoor", systemImage: "macwindow")
        }
        if let release = updates.availableRelease {
            Button {
                updates.download(release)
            } label: {
                Label("Update to \(release.tagName)…", systemImage: "arrow.down.circle.fill")
            }
        } else {
            Button {
                lifecycle.checkForUpdates()
            } label: {
                Label(updates.isChecking ? "Checking for Updates…" : "Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(updates.isChecking)
        }
        Button("Settings…") {
            model.showSettings()
            lifecycle.showMainWindow()
        }
        Divider()
        Button("Quit ModelMoor") { lifecycle.quit() }
    }

    private var gatewayMenu: some View {
        Menu {
            Text(gatewayStatus).disabled(true)
            Divider()
            Button("Copy Unified URL", action: model.copyGatewayURL)
            Button("Copy Unified API Key", action: model.copyGatewayToken)
            if !model.configuration.routes.isEmpty {
                Menu(model.configuration.routes.count == 1 ? "Models, 1" : "Models, \(model.configuration.routes.count)") {
                    ForEach(model.configuration.routes.filter(\.enabled)) { route in
                        Button(route.publicModel) { model.copy(route.publicModel) }
                    }
                }
            }
            Divider()
            Button("Show in ModelMoor") {
                model.showGateway()
                lifecycle.showMainWindow()
            }
        } label: {
            Label("Unified API", systemImage: "point.3.connected.trianglepath.dotted")
        }
    }

    private var endpointMenu: some View {
        Menu {
            if llmEndpoints.isEmpty {
                Text("No API Endpoints").disabled(true)
                Button("Add API Endpoint…") {
                    lifecycle.showMainWindow()
                    model.requestAddEndpoint()
                }
            } else {
                ForEach(llmEndpoints) { endpoint in
                    Menu {
                        Text(endpointStatus(endpoint)).disabled(true)
                        Divider()
                        Button("Copy URL") {
                            if let url = model.endpointURL(endpoint) { model.copy(url.absoluteString) }
                        }
                        let remoteModels = model.inspections[endpoint.id]?.models ?? []
                        if !remoteModels.isEmpty {
                            Menu(remoteModels.count == 1 ? "Copy Model ID" : "Copy Model ID, \(remoteModels.count)") {
                                ForEach(remoteModels.prefix(30)) { remoteModel in
                                    Button(remoteModel.id) { model.copy(remoteModel.id) }
                                }
                            }
                        }
                        Button("Refresh") { Task { await model.inspectEndpoint(endpoint.id) } }
                            .disabled(!endpoint.enabled || model.inspectingEndpointIDs.contains(endpoint.id))
                        Divider()
                        Button("Show in ModelMoor") {
                            model.showEndpoint(endpoint.id)
                            lifecycle.showMainWindow()
                        }
                    } label: {
                        Label(endpoint.name, systemImage: endpointSymbol(endpoint))
                    }
                }
            }
        } label: {
            Label("API Endpoints", systemImage: "link")
        }
    }

    private var otherServicesMenu: some View {
        Menu {
            ForEach(otherEndpoints) { endpoint in
                Menu {
                    Button("Copy URL") {
                        if let url = model.endpointURL(endpoint) { model.copy(url.absoluteString) }
                    }
                    Divider()
                    Button("Show in ModelMoor") {
                        model.showEndpoint(endpoint.id)
                        lifecycle.showMainWindow()
                    }
                } label: {
                    Label(endpoint.name, systemImage: "arrow.left.arrow.right")
                }
            }
        } label: {
            Label("Others", systemImage: "square.stack.3d.up")
        }
    }

    private var connectionMenu: some View {
        Menu {
            if model.configuration.tunnels.isEmpty {
                Text("No SSH Connections").disabled(true)
                Button("New SSH Connection…") {
                    lifecycle.showMainWindow()
                    model.requestAddSSHConnection()
                }
            } else {
                ForEach(model.configuration.tunnels) { connection in
                    Menu {
                        Text(model.status(for: connection.id).message).disabled(true)
                        Divider()
                        Button(connectionActionTitle(connection)) {
                            Task {
                                if isActive(connection) { await model.disconnect(connection.id) }
                                else { await model.connect(connection.id) }
                            }
                        }
                        .disabled(connection.enabledMappings.isEmpty)
                        Button("Show in ModelMoor") {
                            model.showConnection(connection.id)
                            lifecycle.showMainWindow()
                        }
                    } label: {
                        Label(connection.name, systemImage: connectionSymbol(connection))
                    }
                }
                Divider()
                Button("Connect All") { Task { await model.connectAll() } }
                Button("Disconnect All") { Task { await model.disconnectAll() } }
                Divider()
                Button("New SSH Connection…") {
                    lifecycle.showMainWindow()
                    model.requestAddSSHConnection()
                }
            }
        } label: {
            Label("SSH Connections", systemImage: "network")
        }
    }

    private var attentionMenu: some View {
        Menu {
            ForEach(attentionItems, id: \.id) { item in
                Button {
                    model.showEndpoint(item.id)
                    lifecycle.showMainWindow()
                } label: {
                    Label("\(item.name), \(compact(item.message))", systemImage: "exclamationmark.triangle.fill")
                }
            }
            if let error = model.errorMessage {
                Button {
                    model.navigationRequest = .overview
                    lifecycle.showMainWindow()
                } label: {
                    Label(compact(error), systemImage: "exclamationmark.triangle.fill")
                }
            }
        } label: {
            Label("Needs Attention, \(attentionCount)", systemImage: "exclamationmark.triangle.fill")
        }
    }

    private var attentionItems: [(id: UUID, name: String, message: String)] {
        llmEndpoints.compactMap { endpoint in
            guard let message = model.inspections[endpoint.id]?.errorMessage else { return nil }
            return (endpoint.id, endpoint.name, message)
        }
    }

    private var attentionCount: Int { attentionItems.count + (model.errorMessage == nil ? 0 : 1) }

    private var overallStatus: String {
        if attentionCount > 0 { return "Needs Attention" }
        if model.configuration.gateway.enabled {
            if case .running = model.gatewayState { return "Ready" }
            return "Starting"
        }
        let ready = llmEndpoints.filter { model.inspections[$0.id]?.errorMessage == nil && model.inspections[$0.id]?.statusCode != nil }.count
        return ready > 0 ? "Ready" : "Idle"
    }

    private var llmEndpoints: [APIEndpointConfiguration] {
        model.configuration.endpoints.filter(model.isRecognizedLLMEndpoint)
    }

    private var otherEndpoints: [APIEndpointConfiguration] {
        model.configuration.endpoints.filter { !model.isRecognizedLLMEndpoint($0) }
    }

    private var gatewayStatus: String {
        switch model.gatewayState {
        case .stopped: "Starting"
        case let .running(port): "Ready, 127.0.0.1:\(port), \(model.configuration.routes.filter(\.enabled).count) models"
        case let .failed(message): "Needs attention, \(compact(message))"
        }
    }

    private func endpointStatus(_ endpoint: APIEndpointConfiguration) -> String {
        if !endpoint.enabled { return "Disabled" }
        if model.inspectingEndpointIDs.contains(endpoint.id) { return "Checking" }
        guard let inspection = model.inspections[endpoint.id] else { return "Not checked" }
        return inspection.errorMessage ?? "Ready, \(inspection.models?.count ?? 0) models"
    }

    private func endpointSymbol(_ endpoint: APIEndpointConfiguration) -> String {
        if !endpoint.enabled { return "circle" }
        if model.inspectingEndpointIDs.contains(endpoint.id) { return "arrow.triangle.2.circlepath" }
        guard let inspection = model.inspections[endpoint.id] else { return "questionmark.circle" }
        return inspection.errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func isActive(_ connection: TunnelConfiguration) -> Bool {
        switch model.status(for: connection.id).phase {
        case .waitingForNetwork, .connecting, .connected, .disconnecting, .waitingToRetry: true
        case .stopped, .failed: false
        }
    }

    private func connectionActionTitle(_ connection: TunnelConfiguration) -> String {
        isActive(connection) ? "Disconnect" : (model.status(for: connection.id).phase == .failed ? "Retry" : "Connect")
    }

    private func connectionSymbol(_ connection: TunnelConfiguration) -> String {
        switch model.status(for: connection.id).phase {
        case .stopped: "circle"
        case .waitingForNetwork: "wifi.slash"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .disconnecting: "stop.circle"
        case .waitingToRetry: "clock.arrow.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func compact(_ value: String, limit: Int = 72) -> String {
        value.count <= limit ? value : String(value.prefix(limit - 1)) + "…"
    }
}
