import ModelMoorCore
import ModelMoorSystem
import SwiftUI

struct AddEndpointFlow: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var step = 0
    @State private var source: EndpointSourceChoice = .ssh
    @State private var preset: EndpointPreset = .openAI
    @State private var name = ""
    @State private var sshHost = ""
    @State private var remotePort = 8_888
    @State private var baseURL = ""
    @State private var token = ""
    @State private var inspection: EndpointInspection?
    @State private var isTesting = false
    @State private var isCreating = false
    @State private var creationError: String?
    @State private var selectedMappingID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add API endpoint").font(.title2.weight(.semibold))
                    Text(stepTitle).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Step \(step + 1) of 3")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            Divider()

            Group {
                switch step {
                case 0: chooseSource
                case 1: apiDetails
                default: testAndCreate
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)

            Divider()
            actionBar
        }
        .frame(width: 620, height: 500)
        .onAppear {
            sshHost = sshHost.isEmpty ? (model.sshTargets.first?.alias ?? "") : sshHost
            if let mappingID = model.preferredEndpointMappingID {
                source = .existingSSH
                selectedMappingID = mappingID
                model.preferredEndpointMappingID = nil
                step = 1
                useDiscoveredPreset()
            } else {
                selectedMappingID = model.importableSSHPorts.first?.mapping.id
            }
        }
        .interactiveDismissDisabled(isTesting || isCreating)
        .onChange(of: source) { _, value in
            if value != .direct, !availablePresets.contains(preset) { preset = .openAI }
            if value == .direct, baseURL.isEmpty { baseURL = preset.defaultBaseURL }
            if value == .existingSSH { useDiscoveredPreset() }
        }
        .onChange(of: selectedMappingID) { _, _ in
            inspection = nil
            useDiscoveredPreset()
        }
    }

    private var chooseSource: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where is the API running?").font(.headline)
            Picker("Source", selection: $source) {
                Label("Remote over SSH", systemImage: "network").tag(EndpointSourceChoice.ssh)
                Label("Existing SSH port", systemImage: "arrow.down.to.line").tag(EndpointSourceChoice.existingSSH)
                Label("Direct HTTP(S) API", systemImage: "globe").tag(EndpointSourceChoice.direct)
            }
            .pickerStyle(.radioGroup)
            if source != .existingSSH { Text(source == .ssh
                 ? "ModelMoor creates a loopback port forward and keeps the SSH connection available in the background."
                 : "Use a commercial or self-hosted HTTP or HTTPS endpoint that this Mac can reach directly.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var apiDetails: some View {
        Form {
            Section("API") {
                TextField("Name", text: $name, prompt: Text(source == .ssh ? "DGX Spark API" : "Cloud API"))
                Picker("Preset", selection: $preset) {
                    ForEach(availablePresets) { preset in Text(preset.title).tag(preset) }
                }
                .onChange(of: preset) { previous, value in
                    inspection = nil
                    guard source == .direct else { return }
                    if name.isEmpty || name == previous.title { name = value.title }
                    if baseURL.isEmpty || baseURL == previous.defaultBaseURL {
                        baseURL = value.defaultBaseURL
                    }
                }
            }

            if source == .ssh {
                Section("SSH Connection") {
                    LabeledContent("SSH alias") {
                        HStack {
                            SSHHostComboBox(value: $sshHost, targets: model.sshTargets)
                            Button {
                                Task { await model.refreshSSHTargets() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Reload ~/.ssh/config")
                            .accessibilityLabel("Reload SSH configuration")
                        }
                    }
                    LabeledContent("Remote API port") {
                        TextField("Port", value: $remotePort, format: .number.grouping(.never))
                            .frame(width: 86)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("The local port is allocated automatically and remains loopback-only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if source == .existingSSH {
                Section("Existing SSH port") {
                    Picker("Port forward", selection: $selectedMappingID) {
                        Text("Select a port forward").tag(nil as UUID?)
                        ForEach(model.importableSSHPorts, id: \.mapping.id) { port in
                            Text(verbatim: "\(port.tunnel.name) · \(port.mapping.name) · 127.0.0.1:\(port.mapping.listenPort)")
                                .tag(Optional(port.mapping.id))
                        }
                    }
                    if model.importableSSHPorts.isEmpty {
                        Text("No unused local SSH forwards").foregroundStyle(.secondary)
                    } else if let port = selectedPort {
                        Text(model.status(for: port.tunnel.id).phase == .connected ? "Connected" : "Connect SSH to detect the API")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Direct Connection") {
                    TextField(
                        "HTTP(S) base URL",
                        text: $baseURL,
                        prompt: Text(verbatim: "https://api.example.com/v1")
                    )
                    SecureField(preset == .deepSeek ? "DeepSeek API key" : "API key, optional", text: $token)
                    Text("The key is stored in the private secrets file and is never written to the ModelMoor configuration file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if source != .direct && (preset.usesBearerAuthentication || source == .existingSSH) {
                Section("Authentication") {
                    SecureField("Bearer API key, optional", text: $token)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var testAndCreate: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Test and create").font(.headline)

            if source == .ssh {
                LayerResult(symbol: "checkmark.circle.fill", title: "SSH configuration", detail: sshHost, color: .green)
                LayerResult(symbol: "checkmark.circle.fill", title: "Port forward", detail: "Local loopback → 127.0.0.1:\(remotePort)", color: .green)
                LayerResult(
                    symbol: "clock",
                    title: "API and models",
                    detail: "Checked immediately after the SSH connection starts",
                    color: .secondary
                )
            } else if source == .existingSSH && !canTestSelectedPort {
                Text("Connect SSH to detect the API").foregroundStyle(.secondary)
            } else if isTesting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking model list…")
                }
            } else if let inspection {
                LayerResult(
                    symbol: inspection.errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    title: inspection.errorMessage == nil ? "API is ready" : "API needs attention",
                    detail: inspection.errorMessage ?? "HTTP \(inspection.statusCode ?? 0), \(inspection.models?.count ?? 0) models",
                    color: inspection.errorMessage == nil ? .green : .orange
                )
                if let url = inspection.url {
                    LabeledContent("Test URL") {
                        Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            } else {
                Text("Run a read-only model-list request before creating this endpoint.")
                    .foregroundStyle(.secondary)
            }

            if let error = creationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isTesting || isCreating)
            if step > 0 {
                Button("Back") { step -= 1; inspection = nil; creationError = nil }
                    .disabled(isTesting || isCreating)
            }
            Spacer()
            if isCreating { ProgressView().controlSize(.small) }
            if step < 2 {
                Button("Continue") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 1 && !detailsAreValid)
            } else if source != .ssh && inspection == nil && (source == .direct || canTestSelectedPort) {
                Button("Test Endpoint", action: testDirect)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isTesting)
            } else if source != .ssh, inspection?.errorMessage != nil {
                Button("Retry Test", action: testDirect)
                    .disabled(isTesting)
                Button("Create Anyway", action: create)
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreating || !detailsAreValid)
            } else {
                Button("Create Endpoint", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || !detailsAreValid)
            }
        }
        .padding(16)
    }

    private var stepTitle: String {
        switch step {
        case 0: "Choose source"
        case 1: "API details"
        default: "Test and create"
        }
    }

    private var detailsAreValid: Bool {
        if source == .existingSSH { return selectedPort != nil }
        if source == .ssh { return !sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...65_535).contains(remotePort) }
        let validURL = (try? EndpointURLResolver.parseDirectBaseURL(baseURL)) != nil
        return validURL && (![EndpointPreset.deepSeek, .openRouter].contains(preset) || !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var availablePresets: [EndpointPreset] {
        source == .direct ? EndpointPreset.allCases : [.openAI, .lmStudio, .ollama, .custom]
    }

    private func testDirect() {
        isTesting = true
        inspection = nil
        Task {
            if source == .existingSSH, let selectedMappingID {
                inspection = await model.testSSHPort(mappingID: selectedMappingID, preset: preset, token: token)
            } else {
                inspection = await model.testDirectEndpoint(name: name, baseURL: baseURL, preset: preset, token: token)
            }
            isTesting = false
        }
    }

    private var selectedPort: (tunnel: TunnelConfiguration, mapping: PortMappingConfiguration)? {
        model.importableSSHPorts.first { $0.mapping.id == selectedMappingID }
    }

    private var canTestSelectedPort: Bool {
        guard let port = selectedPort else { return false }
        return model.status(for: port.tunnel.id).phase == .connected
    }

    private func useDiscoveredPreset() {
        guard source == .existingSSH, let port = selectedPort else { return }
        name = port.mapping.name
        preset = .openAI
        if let discovery = model.mappingDiscoveries[port.mapping.id], discovery.inspection.classification == .llmAPI {
            preset = discovery.endpoint.kind == .ollama ? .ollama : .openAI
        }
    }

    private func create() {
        guard !isCreating else { return }
        creationError = nil
        isCreating = true
        Task {
            let createdID: UUID?
            if source == .ssh {
                createdID = await model.createSSHEndpoint(
                    name: name,
                    sshHost: sshHost,
                    remotePort: remotePort,
                    preset: preset,
                    token: token
                )
            } else if source == .existingSSH, let selectedMappingID {
                createdID = await model.importSSHPort(mappingID: selectedMappingID, name: name, preset: preset, token: token)
            } else {
                createdID = await model.createDirectEndpoint(
                    name: name,
                    baseURL: baseURL,
                    preset: preset,
                    token: token
                )
            }
            isCreating = false
            if createdID != nil { dismiss() }
            else { creationError = model.errorMessage }
        }
    }
}

private struct LayerResult: View {
    let symbol: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
