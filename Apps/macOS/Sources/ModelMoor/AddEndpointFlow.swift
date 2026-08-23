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
        }
        .interactiveDismissDisabled(isTesting || isCreating)
    }

    private var chooseSource: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where is the API running?").font(.headline)
            Picker("Source", selection: $source) {
                Label("Remote over SSH", systemImage: "network").tag(EndpointSourceChoice.ssh)
                Label("Direct HTTPS API", systemImage: "lock.shield").tag(EndpointSourceChoice.direct)
            }
            .pickerStyle(.radioGroup)
            Text(source == .ssh
                 ? "ModelMoor creates a loopback port forward and keeps the SSH connection available in the background."
                 : "Use a commercial or self-hosted HTTPS endpoint that this Mac can reach directly.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var apiDetails: some View {
        Form {
            Section("API") {
                TextField("Name", text: $name, prompt: Text(source == .ssh ? "DGX Spark API" : "Cloud API"))
                Picker("Preset", selection: $preset) {
                    ForEach(availablePresets) { preset in Text(preset.title).tag(preset) }
                }
                .onChange(of: preset) { _, value in
                    guard source == .direct, value == .deepSeek else { return }
                    if name.isEmpty { name = "DeepSeek" }
                    baseURL = "https://api.deepseek.com"
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
            } else {
                Section("Direct Connection") {
                    TextField(
                        "HTTPS base URL",
                        text: $baseURL,
                        prompt: Text(verbatim: "https://api.example.com/v1")
                    )
                    SecureField(preset == .deepSeek ? "DeepSeek API key" : "API key, optional", text: $token)
                    Text("The key is stored in Keychain and is never written to the ModelMoor configuration file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if source == .ssh && preset == .openAI {
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

            if let error = model.errorMessage, isCreating {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if step > 0 { Button("Back") { step -= 1; inspection = nil } }
            Spacer()
            if step < 2 {
                Button("Continue") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 1 && !detailsAreValid)
            } else if source == .direct && inspection == nil {
                Button("Test Endpoint", action: testDirect)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isTesting)
            } else if source == .direct, inspection?.errorMessage != nil {
                Button("Retry Test", action: testDirect)
                    .disabled(isTesting)
                Button("Create Anyway", action: create)
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreating)
            } else {
                Button("Create Endpoint", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating)
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
        if source == .ssh { return !sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...65_535).contains(remotePort) }
        let validURL = baseURL.lowercased().hasPrefix("https://")
        return validURL && (preset != .deepSeek || !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var availablePresets: [EndpointPreset] {
        source == .direct ? EndpointPreset.allCases : EndpointPreset.allCases.filter { $0 != .deepSeek }
    }

    private func testDirect() {
        isTesting = true
        inspection = nil
        Task {
            inspection = await model.testDirectEndpoint(name: name, baseURL: baseURL, preset: preset, token: token)
            isTesting = false
        }
    }

    private func create() {
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
