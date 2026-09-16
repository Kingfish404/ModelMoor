import ModelMoorApplication
import ModelMoorCore
import ModelMoorSystem
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var lifecycle: AppLifecycleController
    @EnvironmentObject private var updates: UpdateController

    var body: some View {
        Text("\(model.runtimeProfile.displayName), \(overallStatus)").disabled(true)

        if model.configuration.gateway.enabled { gatewayMenu }
        endpointMenu
        if !otherEndpoints.isEmpty { otherServicesMenu }
        connectionMenu
        if !attentionItems.isEmpty || model.errorMessage != nil { attentionMenu }

        Divider()
        Button {
            Task { await model.inspectAllEndpoints() }
        } label: {
            Text(model.isInspectingAllEndpoints ? "Refreshing Status…" : "Refresh Status")
        }
        .disabled(!canRefreshAllEndpoints)

        Button("Reload", action: lifecycle.reloadConfiguration)
            .disabled(lifecycle.isReloadingConfiguration || !model.isLoaded)

        Button { lifecycle.showMainWindow() } label: {
            Text("Open \(model.runtimeProfile.displayName)")
        }
        if let release = updates.availableRelease {
            Button {
                updates.download(release)
            } label: {
                Text("Update to \(release.tagName)…")
            }
        } else if updates.updatesAvailable {
            Button {
                lifecycle.checkForUpdates()
            } label: {
                Text(updates.isChecking ? "Checking for Updates…" : "Check for Updates…")
            }
            .disabled(updates.isChecking)
        }
        Button("Settings…") {
            model.showSettings()
            lifecycle.showMainWindow()
        }
        Button("Copy Diagnostic Summary") {
            Task { await model.copyDiagnosticSummary() }
        }
        Divider()
        Button("Quit \(model.runtimeProfile.displayName)") { lifecycle.quit() }
    }

    private var gatewayMenu: some View {
        Menu {
            Text(gatewayStatus).disabled(true)
            Divider()
            Button("Copy Unified URL", action: model.copyGatewayURL)
            Button("Copy Unified API Key") {
                Task { await model.copyGatewayToken() }
            }
            .disabled(model.isUpdatingGatewayAccess)
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
            Text("Unified API")
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
                        let resolvedURL = model.endpointURL(endpoint)
                        Button("Copy URL") {
                            guard let resolvedURL else { return }
                            model.copy(resolvedURL.absoluteString)
                        }
                        .disabled(!EndpointInteractionPolicy.canCopyURL(resolvedURL))
                        let remoteModels = model.inspections[endpoint.id]?.models ?? []
                        if !remoteModels.isEmpty {
                            Menu(remoteModels.count == 1 ? "Copy Model ID" : "Copy Model ID, \(remoteModels.count)") {
                                ForEach(remoteModels.prefix(30)) { remoteModel in
                                    Button(remoteModel.id) { model.copy(remoteModel.id) }
                                }
                            }
                        }
                        Button("Refresh") { Task { await model.inspectEndpoint(endpoint.id) } }
                            .disabled(!EndpointInteractionPolicy.canRefresh(
                                endpoint,
                                inspectingEndpointIDs: model.inspectingEndpointIDs
                            ))
                        Divider()
                        Button("Show in ModelMoor") {
                            model.showEndpoint(endpoint.id)
                            lifecycle.showMainWindow()
                        }
                    } label: {
                        Text(endpoint.name)
                    }
                }
            }
        } label: {
            Text("API Endpoints")
        }
    }

    private var otherServicesMenu: some View {
        Menu {
            ForEach(otherEndpoints) { endpoint in
                Menu {
                    let resolvedURL = model.endpointURL(endpoint)
                    Button("Copy URL") {
                        guard let resolvedURL else { return }
                        model.copy(resolvedURL.absoluteString)
                    }
                    .disabled(!EndpointInteractionPolicy.canCopyURL(resolvedURL))
                    Divider()
                    Button("Show in ModelMoor") {
                        model.showEndpoint(endpoint.id)
                        lifecycle.showMainWindow()
                    }
                } label: {
                    Text(endpoint.name)
                }
            }
        } label: {
            Text("Others")
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
                    let phase = model.status(for: connection.id).phase
                    Menu {
                        Text(model.status(for: connection.id).message).disabled(true)
                        Divider()
                        Button(phase.connectionActionTitle) {
                            Task {
                                if phase.usesDisconnectAction { await model.disconnect(connection.id) }
                                else { await model.connect(connection.id) }
                            }
                        }
                        .disabled(!ConnectionInteractionPolicy.canPerformPrimaryAction(
                            connection,
                            phase: phase
                        ))
                        Button("Show in ModelMoor") {
                            model.showConnection(connection.id)
                            lifecycle.showMainWindow()
                        }
                    } label: {
                        Text(connection.name)
                    }
                }
                Divider()
                Button("Connect All") { Task { await model.connectAll() } }
                    .disabled(!model.canConnectAll)
                Button("Disconnect All") { Task { await model.disconnectAll() } }
                    .disabled(!model.canDisconnectAll)
                Divider()
                Button("New SSH Connection…") {
                    lifecycle.showMainWindow()
                    model.requestAddSSHConnection()
                }
            }
        } label: {
            Text("SSH Connections")
        }
    }

    private var attentionMenu: some View {
        Menu {
            ForEach(attentionItems, id: \.id) { item in
                Button {
                    model.showEndpoint(item.id)
                    lifecycle.showMainWindow()
                } label: {
                    Text("\(item.name), \(compact(item.message))")
                }
            }
            if let error = model.errorMessage {
                Button {
                    model.navigationRequest = .overview
                    lifecycle.showMainWindow()
                } label: {
                    Text(compact(error))
                }
            }
        } label: {
            Text("Needs Attention, \(attentionCount)")
        }
    }

    private var attentionItems: [(id: UUID, name: String, message: String)] {
        llmEndpoints.compactMap { endpoint in
            guard let message = model.inspections[endpoint.id]?.errorMessage else { return nil }
            return (endpoint.id, endpoint.name, message)
        }
    }

    private var attentionCount: Int { attentionItems.count + (model.errorMessage == nil ? 0 : 1) }

    private var canRefreshAllEndpoints: Bool {
        EndpointInteractionPolicy.canRefreshAll(
            endpoints: model.configuration.endpoints,
            inspectingEndpointIDs: model.inspectingEndpointIDs
        )
    }

    private var overallStatus: String {
        if attentionCount > 0 { return AppLocalization.string("Needs Attention") }
        if model.configuration.gateway.enabled {
            if case .running = model.gatewayState { return AppLocalization.string("Ready") }
            return AppLocalization.string("Starting")
        }
        let ready = llmEndpoints.filter { model.inspections[$0.id]?.errorMessage == nil && model.inspections[$0.id]?.statusCode != nil }.count
        return AppLocalization.string(ready > 0 ? "Ready" : "Idle")
    }

    private var llmEndpoints: [APIEndpointConfiguration] {
        model.configuration.endpoints.filter(model.isRecognizedLLMEndpoint)
    }

    private var otherEndpoints: [APIEndpointConfiguration] {
        model.configuration.endpoints.filter { !model.isRecognizedLLMEndpoint($0) }
    }

    private var gatewayStatus: String {
        switch model.gatewayState {
        case .stopped: AppLocalization.string("Starting")
        case let .running(port): AppLocalization.format(
            "Ready, 127.0.0.1:%lld, %lld models",
            Int64(port),
            Int64(model.configuration.routes.filter(\.enabled).count)
        )
        case let .failed(message): AppLocalization.format("Needs attention, %@", compact(message))
        }
    }

    private func endpointStatus(_ endpoint: APIEndpointConfiguration) -> String {
        if !endpoint.enabled { return AppLocalization.string("Disabled") }
        if model.inspectingEndpointIDs.contains(endpoint.id) { return AppLocalization.string("Checking") }
        guard let inspection = model.inspections[endpoint.id] else { return AppLocalization.string("Not checked") }
        let count = inspection.models?.count ?? 0
        return inspection.errorMessage
            ?? AppLocalization.format(count == 1 ? "Ready, %lld model" : "Ready, %lld models", Int64(count))
    }

    private func compact(_ value: String, limit: Int = 72) -> String {
        value.count <= limit ? value : String(value.prefix(limit - 1)) + "…"
    }
}
