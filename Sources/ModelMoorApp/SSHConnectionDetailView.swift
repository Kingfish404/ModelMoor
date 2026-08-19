import ModelMoorCore
import SwiftUI

struct SSHConnectionDetailView: View {
    @EnvironmentObject private var model: AppModel
    let connectionID: UUID
    @Binding var selection: NavigationSelection?
    @State private var draft: TunnelConfiguration?
    @State private var showsAdvanced = false
    @State private var showsDeleteConfirmation = false
    @State private var forwardEditor: ForwardEditorContext?

    var body: some View {
        Group {
            if let binding = draftBinding {
                VStack(spacing: 0) {
                    header(binding.wrappedValue)
                    Divider()
                    Form {
                        basics(binding)
                        usedBy(binding.wrappedValue)
                        forwards(binding)
                        advanced(binding)
                        Section {
                            Button("Delete SSH Connection…", role: .destructive) {
                                showsDeleteConfirmation = true
                            }
                        }
                    }
                    .formStyle(.grouped)
                    if isDirty { applyBar(binding.wrappedValue) }
                }
            } else {
                ContentUnavailableView("SSH connection not found", systemImage: "network.slash")
            }
        }
        .navigationTitle(draft?.name ?? "SSH Connection")
        .onAppear(perform: reloadDraft)
        .onChange(of: connectionID) { _, _ in reloadDraft() }
        .sheet(item: $forwardEditor) { editor in
            RawPortForwardSheet(
                mapping: editor.mapping,
                sshHost: draft?.sshHost ?? "",
                isNew: editor.isNew,
                directionLocked: editor.directionLocked,
                reservedNames: reservedForwardNames(excluding: editor.mapping.id)
            ) { updated in
                guard var draft else { return }
                if editor.isNew {
                    draft.mappings.append(updated)
                } else if let index = draft.mappings.firstIndex(where: { $0.id == updated.id }) {
                    draft.mappings[index] = updated
                }
                self.draft = draft
            }
        }
        .confirmationDialog("Delete this SSH connection?", isPresented: $showsDeleteConfirmation) {
            Button(deleteButtonTitle, role: .destructive) {
                model.selectedTunnelID = connectionID
                Task {
                    await model.removeSelectedTunnel()
                    selection = .overview
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    private func header(_ connection: TunnelConfiguration) -> some View {
        let status = model.status(for: connection.id)
        return HStack(spacing: 14) {
            Image(systemName: statusSymbol(status.phase))
                .font(.title2)
                .foregroundStyle(statusColor(status.phase))
                .frame(width: 36, height: 36)
                .background(statusColor(status.phase).opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.message).font(.headline)
                Text("SSH alias \(connection.sshHost), \(connection.enabledMappings.count) active forwards")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(status.phase == .connected ? "Disconnect" : "Connect") {
                Task {
                    if status.phase == .connected { await model.disconnect(connection.id) }
                    else { await model.connect(connection.id) }
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Run Diagnostics") { Task { await model.inspectMappings(in: connection.id) } }
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 76)
        .accessibilityElement(children: .combine)
    }

    private func basics(_ connection: Binding<TunnelConfiguration>) -> some View {
        Section("Basics") {
            TextField("Name", text: connection.name)
            LabeledContent("SSH alias") {
                HStack {
                    SSHHostComboBox(value: connection.sshHost, targets: model.sshTargets)
                    Button {
                        Task { await model.refreshSSHTargets() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reload ~/.ssh/config")
                    .disabled(model.isRefreshingSSHTargets)
                }
            }
            Toggle("Connect at login", isOn: connection.connectOnLaunch)
            Toggle("Reconnect automatically", isOn: connection.autoReconnect)
        }
    }

    private func usedBy(_ connection: TunnelConfiguration) -> some View {
        Section("Used By") {
            let endpoints = endpointsUsing(connection)
            if endpoints.isEmpty {
                Text("No API endpoints use this connection.").foregroundStyle(.secondary)
            } else {
                ForEach(endpoints) { endpoint in
                    Button {
                        selection = .endpoint(endpoint.id)
                    } label: {
                        HStack {
                            Label(endpoint.name, systemImage: "link")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func forwards(_ connection: Binding<TunnelConfiguration>) -> some View {
        Section {
            ForEach(connection.mappings) { mapping in
                HStack(spacing: 10) {
                    Toggle("", isOn: mapping.enabled).labelsHidden().toggleStyle(.checkbox)
                        .accessibilityLabel("Enable \(mapping.wrappedValue.name)")
                    Text(mapping.wrappedValue.direction.sshFlag)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(mapping.wrappedValue.name)
                            if let endpoint = endpointUsing(mapping.wrappedValue.id) {
                                Text("Used by \(endpoint.name)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(forwardSummary(mapping.wrappedValue))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Edit…") {
                        forwardEditor = ForwardEditorContext(
                            mapping: mapping.wrappedValue,
                            isNew: false,
                            directionLocked: endpointUsing(mapping.wrappedValue.id) != nil
                        )
                    }
                    Button(role: .destructive) {
                        connection.wrappedValue.mappings.removeAll { $0.id == mapping.wrappedValue.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(endpointUsing(mapping.wrappedValue.id) == nil
                          ? "Remove port forward"
                          : "Remove the API endpoint before removing its port forward")
                    .disabled(connection.wrappedValue.mappings.count == 1 || endpointUsing(mapping.wrappedValue.id) != nil)
                }
                .padding(.vertical, 3)
                .contextMenu {
                    Button("Edit Port Forward…") {
                        forwardEditor = ForwardEditorContext(
                            mapping: mapping.wrappedValue,
                            isNew: false,
                            directionLocked: endpointUsing(mapping.wrappedValue.id) != nil
                        )
                    }
                    Button("Copy SSH Argument") {
                        model.copy("\(mapping.wrappedValue.direction.sshFlag) \(mapping.wrappedValue.forwardingSpecification)")
                    }
                }
            }
            Button("Add Raw Port Forward…") {
                let port = nextDraftPort(connection.wrappedValue)
                forwardEditor = ForwardEditorContext(
                    mapping: PortMappingConfiguration(
                        name: "Port forward \(connection.wrappedValue.mappings.count + 1)",
                        listenPort: port,
                        destinationPort: port
                    ),
                    isNew: true,
                    directionLocked: false
                )
            }
        } header: {
            Text("Port Forwards")
        } footer: {
            Text("Fixed forwards connect one destination. Dynamic forwards provide a SOCKS 4/5 proxy on this Mac (-D) or the SSH server (-R).")
        }
    }

    private func advanced(_ connection: Binding<TunnelConfiguration>) -> some View {
        Section {
            DisclosureGroup("Advanced SSH Settings", isExpanded: $showsAdvanced) {
                LabeledContent("Connection timeout") {
                    NumberField(value: connection.connectTimeoutSeconds, suffix: "sec", width: 72)
                }
                LabeledContent("Keepalive interval") {
                    NumberField(value: connection.keepAliveIntervalSeconds, suffix: "sec", width: 72)
                }
                LabeledContent("Failure threshold") {
                    NumberField(value: connection.keepAliveFailureCount, suffix: "misses", width: 72)
                }
                LabeledContent("Control command") {
                    Text("/usr/bin/ssh -M -N \(connection.wrappedValue.sshHost)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Restore Defaults") {
                    connection.wrappedValue.connectTimeoutSeconds = 10
                    connection.wrappedValue.keepAliveIntervalSeconds = 15
                    connection.wrappedValue.keepAliveFailureCount = 3
                }
            }
        }
    }

    private func applyBar(_ connection: TunnelConfiguration) -> some View {
        HStack {
            Text("This SSH connection has unapplied changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Revert") { reloadDraft() }
            Button("Apply Changes") {
                Task {
                    if await model.applyTunnel(connection) { reloadDraft() }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .frame(height: 50)
        .background(.bar)
    }

    private var draftBinding: Binding<TunnelConfiguration>? {
        guard draft != nil else { return nil }
        return Binding(get: { draft! }, set: { draft = $0 })
    }

    private var original: TunnelConfiguration? { model.configuration.tunnels.first { $0.id == connectionID } }
    private var isDirty: Bool { draft != original }

    private var affectedEndpoints: [APIEndpointConfiguration] {
        guard let connection = original else { return [] }
        return endpointsUsing(connection)
    }

    private var affectedRoutes: Int {
        let ids = Set(affectedEndpoints.map(\.id))
        return model.configuration.routes.filter { ids.contains($0.endpointID) }.count
    }

    private var deleteButtonTitle: String {
        affectedEndpoints.isEmpty ? "Delete Connection" : "Delete Connection and \(affectedEndpoints.count) Endpoints"
    }

    private var deleteMessage: String {
        "This removes \(affectedEndpoints.count) API endpoints, \(affectedRoutes) Unified Models, and their Keychain credentials. The remote SSH host is unchanged."
    }

    private func reloadDraft() { draft = original }

    private func endpointsUsing(_ connection: TunnelConfiguration) -> [APIEndpointConfiguration] {
        let mappingIDs = Set(connection.mappings.map(\.id))
        return model.configuration.endpoints.filter { endpoint in
            guard case let .sshMapping(mappingID, _) = endpoint.source else { return false }
            return mappingIDs.contains(mappingID)
        }
    }

    private func nextDraftPort(_ connection: TunnelConfiguration) -> Int {
        let used = Set(model.configuration.tunnels.flatMap(\.mappings).map(\.listenPort))
        var candidate = max(18_888, (connection.mappings.map(\.listenPort).max() ?? 18_887) + 1)
        while used.contains(candidate), candidate < 65_535 { candidate += 1 }
        return candidate
    }

    private func forwardSummary(_ mapping: PortMappingConfiguration) -> String {
        let listenSide = mapping.direction.listensLocally ? "this Mac" : "SSH server"
        if mapping.direction.isDynamic {
            return "SOCKS 4/5 on \(listenSide) \(mapping.listenHost):\(mapping.listenPort)"
        }
        let destinationSide = mapping.direction == .local ? "remote" : "this Mac"
        return "\(listenSide) \(mapping.listenHost):\(mapping.listenPort) → \(destinationSide) \(mapping.destinationHost):\(mapping.destinationPort)"
    }

    private func endpointUsing(_ mappingID: UUID) -> APIEndpointConfiguration? {
        model.configuration.endpoints.first { endpoint in
            guard case let .sshMapping(endpointMappingID, _) = endpoint.source else { return false }
            return endpointMappingID == mappingID
        }
    }

    private func reservedForwardNames(excluding mappingID: UUID) -> Set<String> {
        Set((draft?.mappings ?? [])
            .filter { $0.id != mappingID }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    private func statusSymbol(_ phase: TunnelPhase) -> String {
        switch phase {
        case .stopped: "pause.circle"
        case .waitingForNetwork: "wifi.slash"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .disconnecting: "stop.circle"
        case .waitingToRetry: "clock.arrow.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ phase: TunnelPhase) -> Color {
        switch phase {
        case .connected: .green
        case .connecting: .accentColor
        case .waitingForNetwork, .waitingToRetry: .orange
        case .failed: .red
        case .stopped, .disconnecting: .secondary
        }
    }
}

private struct ForwardEditorContext: Identifiable {
    let mapping: PortMappingConfiguration
    let isNew: Bool
    let directionLocked: Bool
    var id: UUID { mapping.id }
}

private struct NumberField: View {
    @Binding var value: Int
    let suffix: String
    let width: CGFloat

    var body: some View {
        HStack {
            TextField("", value: $value, format: .number.grouping(.never))
                .frame(width: width)
                .multilineTextAlignment(.trailing)
            Text(suffix).foregroundStyle(.secondary)
        }
    }
}
