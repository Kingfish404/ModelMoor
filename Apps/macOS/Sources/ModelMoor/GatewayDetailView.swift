import ModelMoorCore
import ModelMoorSystem
import SwiftUI

struct GatewayDetailView: View {
    @EnvironmentObject private var model: AppModel
    let addEndpoint: () -> Void
    let addModels: () -> Void
    @State private var showsAdvanced = false
    @State private var showsAddAPIKey = false
    @State private var keyToRotate: GatewayAPIKeyConfiguration?
    @State private var keyToDelete: GatewayAPIKeyConfiguration?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                authentication
                if model.configuration.gateway.enabled {
                    models
                    advanced
                } else {
                    disabledContent
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(28)
        }
        .navigationTitle("Unified API")
        .sheet(isPresented: $showsAddAPIKey) {
            AddGatewayAPIKeySheet()
                .environmentObject(model)
        }
        .alert("Rotate this API key?", isPresented: rotationAlertPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Rotate Key", role: .destructive) {
                guard let keyToRotate else { return }
                Task { await model.rotateGatewayAPIKey(keyToRotate.id) }
            }
        } message: {
            Text("Clients using \(keyToRotate?.name ?? "this key") will need the replacement. The new key will be copied to the pasteboard.")
        }
        .alert("Delete this API key?", isPresented: deletionAlertPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Key", role: .destructive) {
                guard let keyToDelete else { return }
                Task { await model.removeGatewayAPIKey(keyToDelete.id) }
            }
        } message: {
            Text("Clients using \(keyToDelete?.name ?? "this key") will immediately lose access.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: gatewaySymbol)
                .font(.title2)
                .foregroundStyle(gatewayColor)
                .frame(width: 40, height: 40)
                .background(gatewayColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(gatewayTitle).font(.title2.weight(.semibold))
                if model.configuration.gateway.enabled {
                    Text(gatewayURL).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(gatewayProtectionSummary)
                        .font(.caption)
                        .foregroundStyle(model.configuration.gateway.requiresAPIKey ? Color.secondary : Color.orange)
                } else {
                    Text("One local URL for the models you choose.")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.configuration.gateway.enabled {
                Button("Copy URL", action: model.copyGatewayURL)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var authentication: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("API access").font(.title2.weight(.semibold))
                    Text("The previous Gateway Token is the default Unified API key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Key…") { showsAddAPIKey = true }
                    .disabled(model.isUpdatingGatewayAccess)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Require API key").font(.body.weight(.medium))
                            Text("Clients send an enabled key as an Authorization bearer token.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Require API key", isOn: requiresAPIKeyBinding)
                            .labelsHidden()
                            .disabled(model.isUpdatingGatewayAccess)
                    }
                    .padding(.vertical, 6)

                    Divider().padding(.vertical, 8)

                    if model.configuration.gateway.apiKeys.isEmpty {
                        Text("No API keys configured")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(Array(model.configuration.gateway.apiKeys.enumerated()), id: \.element.id) { index, key in
                            apiKeyRow(key)
                            if index < model.configuration.gateway.apiKeys.count - 1 {
                                Divider().padding(.vertical, 7)
                            }
                        }
                    }
                }
                .padding(4)
            }
        }
    }

    private func apiKeyRow(_ key: GatewayAPIKeyConfiguration) -> some View {
        HStack(spacing: 12) {
            Image(systemName: key.enabled ? "key.fill" : "key")
                .foregroundStyle(key.enabled ? Color.accentColor : .secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(key.name)
                Text(key.enabled ? "Accepted by Unified API" : "Not accepted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enable \(key.name)", isOn: keyEnabledBinding(key))
                .labelsHidden()
                .disabled(cannotDisable(key) || model.isUpdatingGatewayAccess)
                .help(cannotDisable(key) ? "At least one key must stay enabled while authentication is required." : "Accept this key")
            Button {
                Task { await model.copyGatewayAPIKey(key.id) }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(model.isUpdatingGatewayAccess)
            .help("Copy API key")
            .accessibilityLabel("Copy \(key.name) API key")
            Menu {
                Button("Rotate Key…") { keyToRotate = key }
                Divider()
                Button("Delete Key…", role: .destructive) { keyToDelete = key }
                    .disabled(cannotDelete(key))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .disabled(model.isUpdatingGatewayAccess)
            .fixedSize()
            .help("More key actions")
            .accessibilityLabel("More actions for \(key.name)")
        }
        .padding(.vertical, 3)
    }

    private var disabledContent: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text("Unified API gives local clients a stable OpenAI-compatible endpoint while ModelMoor routes each public model name to its source API.")
                    .fixedSize(horizontal: false, vertical: true)
                if eligibleEndpoints.isEmpty {
                    Button("Add API Endpoint…", action: addEndpoint)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Enable Unified API") {
                        model.configuration.gateway.enabled = true
                        Task { _ = await model.saveGateway() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(4)
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Models").font(.title2.weight(.semibold))
                Text(verbatim: String(model.configuration.routes.filter(\.enabled).count))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Models…", action: addModels)
                    .disabled(eligibleEndpoints.isEmpty)
            }

            if model.configuration.routes.isEmpty {
                ContentUnavailableView {
                    Label("No unified models", systemImage: "cube.transparent")
                } description: {
                    Text("Choose model IDs from an OpenAI-compatible endpoint.")
                } actions: {
                    Button("Add Models…", action: addModels)
                }
                .frame(minHeight: 220)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                    GridRow {
                        Text("Public model").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("API endpoint").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Upstream model").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Status").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(verbatim: "")
                    }
                    Divider().gridCellColumns(5)
                    ForEach(model.configuration.routes) { route in
                        GridRow {
                            Text(route.publicModel).font(.callout.monospaced())
                            Button(endpointName(route.endpointID)) { model.showEndpoint(route.endpointID) }
                                .buttonStyle(.link)
                            Text(route.upstreamModel).font(.callout.monospaced()).foregroundStyle(.secondary)
                            Label(route.enabled ? "Enabled" : "Disabled", systemImage: route.enabled ? "checkmark.circle.fill" : "circle")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(route.enabled ? .green : .secondary)
                            Button(role: .destructive) {
                                model.removeRoute(route.id)
                                Task { _ = await model.saveGateway() }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove model from Unified API")
                            .accessibilityLabel("Remove \(route.publicModel) from Unified API")
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var advanced: some View {
        DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
            Form {
                LabeledContent("Listen port") {
                    TextField("Port", value: $model.configuration.gateway.listenPort, format: .number.grouping(.never))
                        .frame(width: 82)
                        .multilineTextAlignment(.trailing)
                }
                Button("Apply Port Change") { Task { _ = await model.saveGateway() } }
                Divider()
                Button("Disable Unified API", role: .destructive) {
                    model.configuration.gateway.enabled = false
                    Task { _ = await model.saveGateway() }
                }
                Text("Disabling the listener keeps your model list for the next time you enable it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
    }

    private var eligibleEndpoints: [APIEndpointConfiguration] {
        model.configuration.endpoints.filter { $0.enabled && $0.kind == .openAICompatible }
    }

    private var gatewayURL: String { "http://127.0.0.1:\(model.configuration.gateway.listenPort)/v1" }

    private var gatewayProtectionSummary: String {
        if !model.configuration.gateway.requiresAPIKey { return "Bound to this Mac. API key authentication is off." }
        let suffix = activeKeyCount == 1 ? "key" : "keys"
        return "Bound to this Mac and protected by \(activeKeyCount) enabled API \(suffix)."
    }

    private var activeKeyCount: Int {
        model.configuration.gateway.apiKeys.filter(\.enabled).count
    }

    private var requiresAPIKeyBinding: Binding<Bool> {
        Binding(
            get: { model.configuration.gateway.requiresAPIKey },
            set: { required in Task { await model.setGatewayRequiresAPIKey(required) } }
        )
    }

    private func keyEnabledBinding(_ key: GatewayAPIKeyConfiguration) -> Binding<Bool> {
        Binding(
            get: { model.configuration.gateway.apiKeys.first(where: { $0.id == key.id })?.enabled ?? false },
            set: { enabled in Task { await model.setGatewayAPIKeyEnabled(key.id, enabled: enabled) } }
        )
    }

    private func cannotDisable(_ key: GatewayAPIKeyConfiguration) -> Bool {
        model.configuration.gateway.requiresAPIKey && key.enabled && activeKeyCount == 1
    }

    private func cannotDelete(_ key: GatewayAPIKeyConfiguration) -> Bool {
        model.configuration.gateway.requiresAPIKey && key.enabled && activeKeyCount == 1
    }

    private var rotationAlertPresented: Binding<Bool> {
        Binding(get: { keyToRotate != nil }, set: { if !$0 { keyToRotate = nil } })
    }

    private var deletionAlertPresented: Binding<Bool> {
        Binding(get: { keyToDelete != nil }, set: { if !$0 { keyToDelete = nil } })
    }

    private var gatewayTitle: String {
        if !model.configuration.gateway.enabled { return "Unified API is off" }
        return switch model.gatewayState {
        case .stopped: "Starting"
        case .running: "Unified API is ready"
        case let .failed(message): "Needs attention, \(message)"
        }
    }

    private var gatewaySymbol: String {
        switch model.gatewayState {
        case .running: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: model.configuration.gateway.enabled ? "clock" : "circle"
        }
    }

    private var gatewayColor: Color {
        switch model.gatewayState {
        case .running: .green
        case .failed: .orange
        case .stopped: .secondary
        }
    }

    private func endpointName(_ id: UUID) -> String {
        model.configuration.endpoints.first { $0.id == id }?.name ?? "Missing endpoint"
    }
}

private struct AddGatewayAPIKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Add API key").font(.title2.weight(.semibold))
                Text("Give the key a client or device name. The generated value is stored in Keychain and copied to the pasteboard.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField("Name", text: $name, prompt: Text("Spark dashboard"))
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add and Copy") {
                    isSaving = true
                    Task {
                        if await model.createGatewayAPIKey(name: name) { dismiss() }
                        isSaving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}
