import ModelMoorCore
import SwiftUI

struct EndpointDetailView: View {
    @EnvironmentObject private var model: AppModel
    let endpointID: UUID
    let manageModels: () -> Void
    @State private var draft: APIEndpointConfiguration?
    @State private var showsModels = false
    @State private var showsDeleteConfirmation = false

    var body: some View {
        Group {
            if let binding = draftBinding {
                VStack(spacing: 0) {
                    statusHeader(binding.wrappedValue)
                    Divider()
                    Form {
                        basics(binding)
                        connection(binding.wrappedValue)
                        authentication(binding.wrappedValue)
                        if model.isRecognizedLLMEndpoint(binding.wrappedValue) {
                            models(binding.wrappedValue)
                            unifiedAPI(binding.wrappedValue)
                        }
                        advanced(binding)
                        Section {
                            Button(model.isRecognizedLLMEndpoint(binding.wrappedValue) ? "Delete API Endpoint…" : "Delete Other Service…", role: .destructive) {
                                showsDeleteConfirmation = true
                            }
                        }
                    }
                    .formStyle(.grouped)
                    if isDirty { applyBar(binding.wrappedValue) }
                }
            } else {
                ContentUnavailableView("Endpoint not found", systemImage: "link.badge.plus")
            }
        }
        .navigationTitle(draft?.name ?? "API Endpoint")
        .onAppear(perform: reloadDraft)
        .onChange(of: endpointID) { _, _ in reloadDraft() }
        .onChange(of: original?.apiKeys) { _, keys in
            guard let keys else { return }
            draft?.apiKeys = keys
            draft?.activeAPIKeyID = original?.activeAPIKeyID
        }
        .onChange(of: original?.activeAPIKeyID) { _, activeKeyID in
            draft?.activeAPIKeyID = activeKeyID
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $showsDeleteConfirmation
        ) {
            Button(deleteButtonTitle, role: .destructive) {
                Task {
                    await model.removeEndpoint(endpointID)
                    model.navigationRequest = .overview
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    private func statusHeader(_ endpoint: APIEndpointConfiguration) -> some View {
        let isLLMAPI = model.isRecognizedLLMEndpoint(endpoint)
        let symbol = isLLMAPI ? readiness.symbol : "arrow.left.arrow.right.circle"
        let color = isLLMAPI ? readinessColor : Color.secondary
        return HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(isLLMAPI ? readiness.title : "Forwarded service").font(.headline)
                Text(sourceSummary(endpoint)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = model.endpointURL(endpoint) {
                Button("Copy URL") { model.copy(url.absoluteString) }
            }
            Button(model.inspectingEndpointIDs.contains(endpointID) ? "Checking…" : (isLLMAPI ? "Refresh" : "Check Reachability")) {
                Task { await model.inspectEndpoint(endpointID) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!endpoint.enabled || model.inspectingEndpointIDs.contains(endpointID))
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 76)
        .accessibilityElement(children: .combine)
    }

    private func basics(_ endpoint: Binding<APIEndpointConfiguration>) -> some View {
        Section("Basics") {
            TextField("Name", text: endpoint.name)
            LabeledContent("Source", value: sourceType(endpoint.wrappedValue))
            LabeledContent("Preset", value: presetName(endpoint.wrappedValue.kind))
            Toggle("Endpoint enabled", isOn: endpoint.enabled)
        }
    }

    @ViewBuilder
    private func connection(_ endpoint: APIEndpointConfiguration) -> some View {
        Section("Connection") {
            switch endpoint.source {
            case let .directHTTPS(origin):
                LabeledContent("HTTPS origin", value: origin.absoluteString)
                if let url = model.endpointURL(endpoint) {
                    LabeledContent("Base URL") {
                        Text(url.absoluteString).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            case let .sshMapping(mappingID, _):
                if let connection = connectionForMapping(mappingID),
                   let mapping = connection.mappings.first(where: { $0.id == mappingID }) {
                    LabeledContent("Via") {
                        Button(connection.name) { model.showConnection(connection.id) }
                            .buttonStyle(.link)
                    }
                    LabeledContent("Remote API", value: "\(mapping.destinationHost):\(mapping.destinationPort)")
                    LabeledContent("Local endpoint", value: "\(mapping.listenHost):\(mapping.listenPort)")
                } else {
                    Label("The SSH port forward is missing", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func authentication(_ endpoint: APIEndpointConfiguration) -> some View {
        Section("Authentication") {
            LabeledContent("Method", value: authenticationName(endpoint.authentication))
            if endpoint.authentication != .none {
                EndpointTokenEditor(endpointID: endpoint.id)
                    .environmentObject(model)
            }
        }
    }

    private func models(_ endpoint: APIEndpointConfiguration) -> some View {
        Section {
            DisclosureGroup(isExpanded: $showsModels) {
                let remoteModels = model.inspections[endpoint.id]?.models ?? []
                if remoteModels.isEmpty {
                    Text("No model IDs are available yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(remoteModels) { remoteModel in
                        HStack {
                            Text(remoteModel.id).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button {
                                model.copy(remoteModel.id)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy model ID")
                            .accessibilityLabel("Copy \(remoteModel.id)")
                        }
                    }
                }
            } label: {
                let count = model.inspections[endpoint.id]?.models?.count ?? 0
                Text(count == 1 ? "Models, 1 discovered" : "Models, \(count) discovered")
            }
        }
    }

    private func unifiedAPI(_ endpoint: APIEndpointConfiguration) -> some View {
        Section("Unified API") {
            let count = model.configuration.routes.filter { $0.endpointID == endpoint.id && $0.enabled }.count
            LabeledContent("Included models", value: "\(count)")
            Button("Manage Models…", action: manageModels)
                .disabled(endpoint.kind != .openAICompatible)
        }
    }

    private func advanced(_ endpoint: Binding<APIEndpointConfiguration>) -> some View {
        Section {
            DisclosureGroup("Advanced") {
                TextField("Base path", text: endpoint.basePath)
                TextField("Health path", text: endpoint.healthPath)
                TextField(
                    "Model list path",
                    text: Binding(
                        get: { endpoint.wrappedValue.modelListPath ?? "" },
                        set: { endpoint.wrappedValue.modelListPath = $0.isEmpty ? nil : $0 }
                    )
                )
                if let inspection = model.inspections[endpointID] {
                    LabeledContent("Last checked", value: inspection.checkedAt.formatted(date: .abbreviated, time: .shortened))
                    if let url = inspection.url {
                        LabeledContent("Diagnostic URL") {
                            Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func applyBar(_ endpoint: APIEndpointConfiguration) -> some View {
        HStack {
            Text("This endpoint has unapplied changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Revert") { reloadDraft() }
            Button("Apply Changes") {
                Task {
                    if await model.applyEndpoint(endpoint) { reloadDraft() }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .frame(height: 50)
        .background(.bar)
    }

    private var draftBinding: Binding<APIEndpointConfiguration>? {
        guard draft != nil else { return nil }
        return Binding(get: { draft! }, set: { draft = $0 })
    }

    private var original: APIEndpointConfiguration? {
        model.configuration.endpoints.first { $0.id == endpointID }
    }

    private var isDirty: Bool { draft != original }

    private var readiness: EndpointReadiness {
        if original?.enabled == false { return .disabled }
        if model.inspectingEndpointIDs.contains(endpointID) { return .checking }
        if let endpoint = original,
           endpoint.authentication != .none,
           !model.hasToken(for: endpointID) {
            return .needsAttention("Add API key")
        }
        guard let inspection = model.inspections[endpointID] else { return .unknown }
        if let message = inspection.errorMessage { return .needsAttention(message) }
        return .ready(inspection.models?.count ?? 0)
    }

    private var readinessColor: Color {
        switch readiness {
        case .disabled: .secondary
        case .ready: .green
        case .needsAttention: .orange
        case .checking: .accentColor
        case .unknown: .secondary
        }
    }

    private var routeCount: Int { model.configuration.routes.filter { $0.endpointID == endpointID }.count }
    private var deleteConfirmationTitle: String {
        original.map(model.isRecognizedLLMEndpoint) == false ? "Delete this other service?" : "Delete this API endpoint?"
    }
    private var deleteButtonTitle: String {
        if original.map(model.isRecognizedLLMEndpoint) == false { return "Delete Other Service" }
        return routeCount == 0 ? "Delete Endpoint" : "Delete Endpoint and \(routeCount) Unified Models"
    }
    private var deleteMessage: String {
        if original.map(model.isRecognizedLLMEndpoint) == false {
            return "The saved service reference and its Keychain credential will be removed. The SSH port forward remains available on its connection."
        }
        return routeCount == 0
            ? "The endpoint and its Keychain credential will be removed."
            : "This also removes \(routeCount) Unified API model entries and the endpoint's Keychain credential."
    }

    private func reloadDraft() { draft = original }

    private func connectionForMapping(_ mappingID: UUID) -> TunnelConfiguration? {
        model.configuration.tunnels.first { $0.mappings.contains { $0.id == mappingID } }
    }

    private func sourceSummary(_ endpoint: APIEndpointConfiguration) -> String {
        switch endpoint.source {
        case let .directHTTPS(origin): "Direct HTTPS, \(origin.host ?? origin.absoluteString)"
        case let .sshMapping(mappingID, _): "Remote over SSH, \(connectionForMapping(mappingID)?.name ?? "missing connection")"
        }
    }

    private func sourceType(_ endpoint: APIEndpointConfiguration) -> String {
        switch endpoint.source {
        case .directHTTPS: "Direct HTTPS API"
        case .sshMapping: "Remote over SSH"
        }
    }

    private func presetName(_ kind: APIEndpointKind) -> String {
        switch kind {
        case .openAICompatible: "OpenAI-compatible"
        case .ollama: "Ollama"
        case .customHTTP: "Custom HTTP"
        }
    }

    private func authenticationName(_ authentication: APIEndpointAuthentication) -> String {
        switch authentication {
        case .none: "No key"
        case .bearer: "Bearer API key"
        case let .header(name): "Custom header, \(name)"
        }
    }
}

struct EndpointTokenEditor: View {
    @EnvironmentObject private var model: AppModel
    let endpointID: UUID
    @State private var editorMode: EndpointKeyEditorMode?
    @State private var keyPendingRemoval: EndpointAPIKeyConfiguration?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("API keys").font(.headline)
                Spacer()
                Button("Add Key…", systemImage: "plus") {
                    editorMode = .add
                }
            }

            if let endpoint, endpoint.apiKeys.isEmpty {
                Text("No API keys saved. Add one to authenticate this endpoint.")
                    .foregroundStyle(.secondary)
            } else if let endpoint {
                ForEach(Array(endpoint.apiKeys.enumerated()), id: \.element.id) { index, key in
                    if index > 0 { Divider() }
                    apiKeyRow(key, activeKeyID: endpoint.activeAPIKeyID)
                }
            }
        }
        .sheet(item: $editorMode) { mode in
            EndpointAPIKeyEditorSheet(endpointID: endpointID, mode: mode)
                .environmentObject(model)
        }
        .confirmationDialog(
            "Remove this API key?",
            isPresented: Binding(
                get: { keyPendingRemoval != nil },
                set: { if !$0 { keyPendingRemoval = nil } }
            ),
            presenting: keyPendingRemoval
        ) { key in
            Button("Remove \(key.name)", role: .destructive) {
                Task { await model.removeEndpointAPIKey(key.id, endpointID: endpointID) }
                keyPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { keyPendingRemoval = nil }
        } message: { key in
            Text("The key named \(key.name) will be removed from Keychain.")
        }
    }

    private var endpoint: APIEndpointConfiguration? {
        model.configuration.endpoints.first { $0.id == endpointID }
    }

    private func apiKeyRow(
        _ key: EndpointAPIKeyConfiguration,
        activeKeyID: UUID?
    ) -> some View {
        let isActive = key.id == activeKeyID
        let isSaved = model.hasToken(forAPIKey: key.id)
        return HStack(spacing: 10) {
            Button {
                Task { await model.selectEndpointAPIKey(key.id, endpointID: endpointID) }
            } label: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(isActive || !isSaved)
            .accessibilityLabel(isActive ? "Current API key" : "Use \(key.name)")

            VStack(alignment: .leading, spacing: 2) {
                Text(key.name)
                Text(isSaved ? (isActive ? "In use, saved in Keychain" : "Saved in Keychain") : "API key not set")
                    .font(.caption)
                    .foregroundStyle(isSaved ? Color.secondary : Color.orange)
            }
            Spacer()
            Menu {
                Button(isSaved ? "Replace Key…" : "Set Key…") {
                    editorMode = .replace(key)
                }
                Button("Remove Key…", role: .destructive) {
                    keyPendingRemoval = key
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Manage \(key.name)")
        }
        .frame(minHeight: 38)
    }
}

private enum EndpointKeyEditorMode: Identifiable {
    case add
    case replace(EndpointAPIKeyConfiguration)

    var id: String {
        switch self {
        case .add: "add"
        case let .replace(key): "replace-\(key.id.uuidString)"
        }
    }
}

private struct EndpointAPIKeyEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let endpointID: UUID
    let mode: EndpointKeyEditorMode
    @State private var name = ""
    @State private var secret = ""
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title2.weight(.semibold))
                Text("The key is stored in Keychain and is never written to ModelMoor configuration.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)

            Divider()

            Form {
                TextField("Name", text: $name)
                    .disabled(isReplacing)
                SecureField("API key", text: $secret)
                    .textContentType(.password)
            }
            .formStyle(.grouped)
            .padding(.vertical, 8)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(saveTitle, action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
            .padding(16)
        }
        .frame(width: 500, height: 280)
        .onAppear {
            switch mode {
            case .add:
                let count = model.configuration.endpoints
                    .first(where: { $0.id == endpointID })?.apiKeys.count ?? 0
                name = "API key \(count + 1)"
            case let .replace(key):
                name = key.name
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var isReplacing: Bool {
        if case .replace = mode { return true }
        return false
    }

    private var title: String { isReplacing ? "Set API key" : "Add API key" }
    private var saveTitle: String { isReplacing ? "Save Key" : "Add and Use Key" }

    private func save() {
        isSaving = true
        Task {
            let succeeded: Bool
            switch mode {
            case .add:
                succeeded = await model.createEndpointAPIKey(
                    endpointID: endpointID,
                    name: name,
                    secret: secret
                )
            case let .replace(key):
                succeeded = await model.replaceEndpointAPIKey(
                    key.id,
                    endpointID: endpointID,
                    secret: secret
                )
            }
            isSaving = false
            if succeeded { dismiss() }
        }
    }
}
