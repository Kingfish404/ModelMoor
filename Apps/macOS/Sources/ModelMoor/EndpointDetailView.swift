import ModelMoorApplication
import ModelMoorCore
import ModelMoorSystem
import SwiftUI

struct EndpointDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var dirtyDrafts: DirtyDraftCoordinator
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
                        if !isManaged(binding.wrappedValue) {
                            advanced(binding)
                            Section {
                                Button(model.isRecognizedLLMEndpoint(binding.wrappedValue) ? "Delete API Endpoint…" : "Delete Other Service…", role: .destructive) {
                                    showsDeleteConfirmation = true
                                }
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
        .onAppear {
            reloadDraft()
            synchronizeDirtyDraft()
        }
        .onDisappear { dirtyDrafts.unregister(id: draftID) }
        .onChange(of: endpointID) { oldID, _ in
            dirtyDrafts.unregister(id: .endpoint(oldID))
            reloadDraft()
            synchronizeDirtyDraft()
        }
        .onChange(of: draft) { _, _ in synchronizeDirtyDraft() }
        .onChange(of: original) { previous, _ in
            if draft == previous {
                reloadDraft()
                synchronizeDirtyDraft()
            }
        }
        .onChange(of: dirtyDrafts.resolution) { _, resolution in
            guard resolution?.draftID == draftID else { return }
            reloadDraft()
            synchronizeDirtyDraft()
        }
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
                dirtyDrafts.abandon(id: draftID)
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
        let resolvedURL = model.endpointURL(endpoint)
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
            Button("Copy URL") {
                guard let resolvedURL else { return }
                model.copy(resolvedURL.absoluteString)
            }
            .disabled(!EndpointInteractionPolicy.canCopyURL(resolvedURL))
            Button(model.inspectingEndpointIDs.contains(endpointID) ? "Checking…" : (isLLMAPI ? "Refresh" : "Check Reachability")) {
                Task { await model.inspectEndpoint(endpointID) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!EndpointInteractionPolicy.canRefresh(
                endpoint,
                inspectingEndpointIDs: model.inspectingEndpointIDs
            ))
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
                .disabled(isManaged(endpoint.wrappedValue))
        }
    }

    @ViewBuilder
    private func connection(_ endpoint: APIEndpointConfiguration) -> some View {
        Section("Connection") {
            switch endpoint.source {
            case let .directHTTPS(origin):
                LabeledContent("HTTP(S) origin", value: origin.absoluteString)
                if let url = model.endpointURL(endpoint) {
                    LabeledContent("Base URL") {
                        Text(url.absoluteString).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            case let .managedCLIProxy(origin):
                LabeledContent("Managed helper", value: "CLIProxyAPI")
                LabeledContent("Loopback origin", value: origin.absoluteString)
                Text("Provider credentials are managed in Subscription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Manage Subscription") {
                    model.showSubscriptionAccounts()
                }
                .buttonStyle(.link)
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
            if isManaged(endpoint) {
                Text("The internal loopback key is generated from the private secrets file into the helper's private configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if endpoint.authentication != .none {
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

    private func isManaged(_ endpoint: APIEndpointConfiguration) -> Bool {
        if case .managedCLIProxy = endpoint.source { return true }
        return false
    }
    private var deleteConfirmationTitle: String {
        original.map(model.isRecognizedLLMEndpoint) == false ? "Delete this other service?" : "Delete this API endpoint?"
    }
    private var deleteButtonTitle: String {
        if original.map(model.isRecognizedLLMEndpoint) == false { return "Delete Other Service" }
        return routeCount == 0 ? "Delete Endpoint" : "Delete Endpoint and \(routeCount) Unified Models"
    }
    private var deleteMessage: String {
        if original.map(model.isRecognizedLLMEndpoint) == false {
            return "The saved service reference and its file-backed credential will be removed. The SSH port forward remains available on its connection."
        }
        return routeCount == 0
            ? "The endpoint and its file-backed credential will be removed."
            : "This also removes \(routeCount) Unified API model entries and the endpoint's file-backed credential."
    }

    private func reloadDraft() { draft = original }

    private var draftID: DirtyDraftID { .endpoint(endpointID) }

    private func synchronizeDirtyDraft() {
        guard let draft else {
            dirtyDrafts.unregister(id: draftID)
            return
        }
        dirtyDrafts.register(
            id: draftID,
            title: draft.name.isEmpty ? AppLocalization.string("This API endpoint") : "“\(draft.name)”",
            isDirty: isDirty
        ) {
            await model.applyEndpoint(draft)
        }
    }

    private func connectionForMapping(_ mappingID: UUID) -> TunnelConfiguration? {
        model.configuration.tunnels.first { $0.mappings.contains { $0.id == mappingID } }
    }

    private func sourceSummary(_ endpoint: APIEndpointConfiguration) -> String {
        switch endpoint.source {
        case let .directHTTPS(origin): "Direct HTTP(S), \(origin.host ?? origin.absoluteString)"
        case .managedCLIProxy: "Managed subscription proxy on this Mac"
        case let .sshMapping(mappingID, _): "Remote over SSH, \(connectionForMapping(mappingID)?.name ?? "missing connection")"
        }
    }

    private func sourceType(_ endpoint: APIEndpointConfiguration) -> String {
        switch endpoint.source {
        case .directHTTPS: "Direct HTTP(S) API"
        case .managedCLIProxy: "Managed subscription proxy"
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
    @State private var keyPendingRename: EndpointAPIKeyConfiguration?
    @State private var keyName = ""
    @State private var revealedKeys: [UUID: String] = [:]
    @State private var revealGeneration = UUID()

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
                Picker("Routing", selection: Binding(
                    get: { endpoint.activeAPIKeyID },
                    set: { keyID in
                        guard let keyID else { return }
                        Task { await model.selectEndpointAPIKey(keyID, endpointID: endpointID) }
                    }
                )) {
                    ForEach(endpoint.apiKeys.filter { model.hasToken(forAPIKey: $0.id) }) { key in
                        Text(key.name).tag(Optional(key.id))
                    }
                }
                .disabled(endpoint.apiKeys.allSatisfy { !model.hasToken(forAPIKey: $0.id) })
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
        .onChange(of: endpointID) { clearRevealedKeys() }
        .onChange(of: endpoint) { clearRevealedKeys() }
        .onChange(of: editorMode?.id) { clearRevealedKeys() }
        .onDisappear { clearRevealedKeys() }
        .alert("Rename Key", isPresented: Binding(
            get: { keyPendingRename != nil },
            set: { if !$0 { keyPendingRename = nil } }
        )) {
            TextField("Name", text: $keyName)
            Button("Save") {
                guard let key = keyPendingRename else { return }
                let name = keyName
                Task { await model.renameEndpointAPIKey(key.id, endpointID: endpointID, name: name) }
                keyPendingRename = nil
            }
            .disabled(keyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { keyPendingRename = nil }
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
            Text("The key named \(key.name) will be removed from the private secrets file.")
        }
    }

    private var endpoint: APIEndpointConfiguration? {
        model.configuration.endpoints.first { $0.id == endpointID }
    }

    private func clearRevealedKeys() {
        revealGeneration = UUID()
        revealedKeys.removeAll()
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
                if let secret = revealedKeys[key.id] {
                    Text(verbatim: secret)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(isSaved ? (isActive ? "In use, saved in the private secrets file" : "Saved in the private secrets file") : "API key not set")
                    .font(.caption)
                    .foregroundStyle(isSaved ? Color.secondary : Color.orange)
            }
            Spacer()
            Button {
                if revealedKeys[key.id] != nil {
                    revealedKeys[key.id] = nil
                } else {
                    let generation = revealGeneration
                    Task {
                        let secret = await model.revealEndpointAPIKey(key.id, endpointID: endpointID)
                        guard generation == revealGeneration else { return }
                        revealedKeys[key.id] = secret
                    }
                }
            } label: {
                Image(systemName: revealedKeys[key.id] == nil ? "eye" : "eye.slash")
            }
            .help(revealedKeys[key.id] == nil ? "Show API Key" : "Hide API Key")
            .accessibilityLabel(revealedKeys[key.id] == nil ? "Show API Key" : "Hide API Key")
            .disabled(!isSaved)
            Button {
                Task { await model.copyEndpointAPIKey(key.id, endpointID: endpointID) }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy API Key")
            .accessibilityLabel("Copy API Key")
            .disabled(!isSaved)
            Menu {
                Button(isSaved ? "Replace Key…" : "Set Key…") {
                    editorMode = .replace(key)
                }
                Button("Rename Key") {
                    keyName = key.name
                    keyPendingRename = key
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
            .accessibilityLabel("Manage \(key.name)")
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
                Text("The key is stored in the private secrets file and is never written to ModelMoor configuration.")
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
