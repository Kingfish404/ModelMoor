import ModelMoorCore
import SwiftUI

struct RawPortForwardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mapping: PortMappingConfiguration
    let sshHost: String
    let isNew: Bool
    let directionLocked: Bool
    let reservedNames: Set<String>
    let save: (PortMappingConfiguration) -> Void

    init(
        mapping: PortMappingConfiguration,
        sshHost: String,
        isNew: Bool,
        directionLocked: Bool = false,
        reservedNames: Set<String>,
        save: @escaping (PortMappingConfiguration) -> Void
    ) {
        _mapping = State(initialValue: mapping)
        self.sshHost = sshHost
        self.isNew = isNew
        self.directionLocked = directionLocked
        self.reservedNames = reservedNames
        self.save = save
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNew ? "Add port forward" : "Edit port forward")
                        .font(.title2.weight(.semibold))
                    Text("Create an OpenSSH fixed or dynamic port forward.")
                        .foregroundStyle(.secondary)
                }

                PortForwardFields(mapping: $mapping, sshHost: sshHost, directionLocked: directionLocked)

                if directionLocked {
                    Label("This forward belongs to an API endpoint, so it must remain a local -L forward.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)

            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Add Port Forward" : "Save Port Forward") {
                    save(mapping)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil)
            }
            .padding(16)
        }
        .frame(width: 660)
    }

    private var validationMessage: String? {
        let normalizedName = mapping.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if reservedNames.contains(normalizedName) { return "Another port forward already uses this name." }
        do {
            _ = try mapping.validated()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct AddSSHConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var sshHost = ""
    @State private var connectOnLaunch = false
    @State private var mapping = PortMappingConfiguration(
        name: "Spark Dashboard",
        direction: .local,
        listenPort: 4_040,
        destinationPort: 4_040
    )
    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New SSH connection").font(.title2.weight(.semibold))
                    Text("Choose an SSH alias and define the first fixed or dynamic port forward.")
                        .foregroundStyle(.secondary)
                }

                Form {
                    Section("Connection") {
                        TextField("Name", text: $name, prompt: Text("DGX Spark"))
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
                            }
                        }
                        Toggle("Connect after creation and at login", isOn: $connectOnLaunch)
                    }
                }
                .formStyle(.grouped)
                .frame(height: 190)

                Divider()
                PortForwardFields(mapping: $mapping, sshHost: sshHost)

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)

            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isCreating ? "Creating…" : "Create SSH Connection") {
                    isCreating = true
                    Task {
                        let id = await model.createSSHConnection(
                            name: name,
                            sshHost: sshHost,
                            connectOnLaunch: connectOnLaunch,
                            firstMapping: mapping
                        )
                        isCreating = false
                        if id != nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil || isCreating)
            }
            .padding(16)
        }
        .frame(width: 680)
        .onAppear { sshHost = sshHost.isEmpty ? (model.sshTargets.first?.alias ?? "") : sshHost }
        .interactiveDismissDisabled(isCreating)
    }

    private var validationMessage: String? {
        let cleanHost = sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.isEmpty { return "Choose an SSH alias or enter a host." }
        let candidate = TunnelConfiguration(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? cleanHost : name,
            sshHost: cleanHost,
            mappings: [mapping],
            connectOnLaunch: connectOnLaunch
        )
        do {
            _ = try candidate.validated()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private struct PortForwardFields: View {
    @Binding var mapping: PortMappingConfiguration
    let sshHost: String
    var directionLocked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Name", text: $mapping.name)

            Picker("Type", selection: $mapping.direction) {
                Text("Local port forwarding (-L)").tag(PortForwardDirection.local)
                Text("Remote port forwarding (-R)").tag(PortForwardDirection.remote)
                Text("Dynamic port forwarding (-D)").tag(PortForwardDirection.dynamic)
                Text("Reverse dynamic port forwarding (-R)").tag(PortForwardDirection.reverseDynamic)
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Port forward type")
            .disabled(directionLocked)

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(directionTitle).font(.headline)
                    Text(directionExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: directionSymbol)
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityElement(children: .combine)

            if mapping.direction.isDynamic {
                HStack {
                    endpointGroup(title: listenTitle, symbol: listenSymbol) {
                        listenerFields
                    }
                    .frame(maxWidth: 310)
                    Spacer()
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    endpointGroup(title: listenTitle, symbol: listenSymbol) {
                        listenerFields
                    }

                    Image(systemName: "arrow.right")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    endpointGroup(title: destinationTitle, symbol: destinationSymbol) {
                        TextField("Host", text: $mapping.destinationHost, prompt: Text("127.0.0.1"))
                        TextField("Port", value: $mapping.destinationPort, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Command preview").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("ssh \(mapping.direction.sshFlag) \(mapping.forwardingSpecification) \(sshHost.isEmpty ? "<ssh-alias>" : sshHost)")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                Text("The listener stays on loopback, so the forwarded port is not exposed to the LAN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var directionTitle: String {
        switch mapping.direction {
        case .local: "Open a remote service on this Mac"
        case .remote: "Expose a service from this Mac to the SSH server"
        case .dynamic: "Run a SOCKS proxy on this Mac"
        case .reverseDynamic: "Run a SOCKS proxy on the SSH server"
        }
    }

    private var directionExplanation: String {
        switch mapping.direction {
        case .local:
            "This Mac listens, then SSH reaches the fixed remote destination."
        case .remote:
            "The SSH server listens, then SSH reaches the fixed destination on this Mac."
        case .dynamic:
            "This Mac accepts SOCKS 4/5 requests, then the SSH server connects to each requested destination."
        case .reverseDynamic:
            "The SSH server accepts SOCKS 4/5 requests, then this Mac connects to each requested destination."
        }
    }

    private var directionSymbol: String {
        switch mapping.direction {
        case .local: "rectangle.portrait.and.arrow.forward"
        case .remote: "arrow.backward.to.line"
        case .dynamic, .reverseDynamic: "network"
        }
    }

    private var listenTitle: String { mapping.direction.listensLocally ? "This Mac listens" : "SSH server listens" }
    private var destinationTitle: String { mapping.direction == .local ? "Remote destination" : "This Mac destination" }
    private var listenSymbol: String { mapping.direction.listensLocally ? "laptopcomputer" : "server.rack" }
    private var destinationSymbol: String { mapping.direction == .local ? "server.rack" : "laptopcomputer" }

    @ViewBuilder
    private var listenerFields: some View {
        Picker("Address", selection: $mapping.listenHost) {
            Text("127.0.0.1").tag("127.0.0.1")
            Text("localhost").tag("localhost")
        }
        TextField("Port", value: $mapping.listenPort, format: .number.grouping(.never))
            .multilineTextAlignment(.trailing)
    }

    private func endpointGroup<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .trailing, spacing: 8) { content() }
                .textFieldStyle(.roundedBorder)
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity)
    }
}
