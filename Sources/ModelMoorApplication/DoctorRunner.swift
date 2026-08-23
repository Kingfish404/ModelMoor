import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ModelMoorCore
import ModelMoorGateway
import ModelMoorSystem

/// `modelmoor doctor` failure layers. The raw values ARE the CLI exit codes
/// and must stay stable for scripts (docs/PLAN.md milestone B).
public enum DoctorLayer: Int, CaseIterable, Comparable, Sendable {
    case configuration = 10
    case system = 20
    case sshTransport = 30
    case endpointAuth = 40
    case apiProtocol = 50
    case gateway = 60

    public static func < (lhs: DoctorLayer, rhs: DoctorLayer) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum DoctorSeverity: String, Sendable {
    case ok
    case warn
    case fail
}

public struct DoctorFinding: Equatable, Sendable {
    public var layer: DoctorLayer
    public var severity: DoctorSeverity
    public var check: String
    public var detail: String
    /// Redacted, actionable next step. Never contains secrets or full paths
    /// beyond the conventionally shareable ones (e.g. `~/.ssh/config`).
    public var suggestion: String?

    public init(
        layer: DoctorLayer,
        severity: DoctorSeverity,
        check: String,
        detail: String,
        suggestion: String? = nil
    ) {
        self.layer = layer
        self.severity = severity
        self.check = check
        self.detail = detail
        self.suggestion = suggestion
    }
}

public struct DoctorReport: Sendable {
    public var findings: [DoctorFinding]

    public init(findings: [DoctorFinding]) {
        self.findings = findings
    }

    /// Highest failing layer's exit code; 0 when nothing failed.
    public var exitCode: Int32 {
        let worst = findings
            .filter { $0.severity == .fail }
            .map(\.layer)
            .max()
        return Int32(worst?.rawValue ?? 0)
    }

    public var hasWarnings: Bool {
        findings.contains { $0.severity == .warn }
    }
}

/// Read-only diagnostics for Moorings, endpoints and the Unified API. Never
/// acquires the runtime owner lock, never mutates configuration or secrets,
/// and never prints token material. Shared by the CLI `doctor` command and
/// (later) the GUI Copy Diagnostic Summary flow.
public struct DoctorRunner: Sendable {
    private let store: ConfigurationStore
    private let profile: ModelMoorRuntimeProfile
    private let secretStoreResolver: @Sendable () throws -> any ModelMoorSecretStore
    private let inspector: any APIInspecting
    private let sshExecutable: URL
    private let batchModeProbe: @Sendable (String) async -> (status: Int32, stderr: String)

    public init(
        store: ConfigurationStore? = nil,
        profile: ModelMoorRuntimeProfile = .current,
        secretStoreResolver: @escaping @Sendable () throws -> any ModelMoorSecretStore = {
            try SecretStoreResolver.defaultStore()
        },
        inspector: any APIInspecting = APIInspector(),
        sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        batchModeProbe: (@Sendable (String) async -> (status: Int32, stderr: String))? = nil
    ) {
        self.profile = profile
        self.secretStoreResolver = secretStoreResolver
        self.inspector = inspector
        self.sshExecutable = sshExecutable
        self.store = store ?? ConfigurationStore(
            fileURL: profile.configurationURL,
            legacyImportURL: profile.legacyConfigurationURL,
            initialConfiguration: profile.initialConfiguration
        )
        self.batchModeProbe = batchModeProbe ?? { host in
            let command = SSHCommand(
                executableURL: sshExecutable,
                arguments: [
                    "-F", "/dev/null",
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=5",
                    "-o", "StrictHostKeyChecking=accept-new",
                    host,
                    "true"
                ]
            )
            let result = await Self.runSSH(command)
            return (result.terminationStatus, result.errorText)
        }
    }

    public func run() async -> DoctorReport {
        var findings: [DoctorFinding] = []
        let configuration = await checkConfiguration(&findings)
        await checkSystem(&findings)
        if let configuration {
            await checkSSHSyntax(configuration: configuration, findings: &findings)
            await checkSSHTransport(configuration: configuration, findings: &findings)
            await checkLocalPorts(configuration: configuration, findings: &findings)
            await checkEndpoints(configuration: configuration, findings: &findings)
            await checkGateway(configuration: configuration, findings: &findings)
        }
        return DoctorReport(findings: findings)
    }

    // MARK: - Layers

    private func checkConfiguration(_ findings: inout [DoctorFinding]) async -> ModelMoorConfiguration? {
        do {
            let configuration = try await store.load()
            findings.append(DoctorFinding(
                layer: .configuration,
                severity: .ok,
                check: "configuration",
                detail: "schema v\(ModelMoorConfiguration.currentSchemaVersion), \(configuration.tunnels.count) mooring(s), \(configuration.endpoints.count) endpoint(s)"
            ))
            return configuration
        } catch {
            findings.append(DoctorFinding(
                layer: .configuration,
                severity: .fail,
                check: "configuration",
                detail: error.localizedDescription,
                suggestion: "Fix or remove the configuration file shown by `modelmoor config-path`; backups sit next to it."
            ))
            return nil
        }
    }

    private func checkSystem(_ findings: inout [DoctorFinding]) async {
        // OpenSSH presence (`ssh -V` prints to stderr on some platforms and
        // stdout on others, so both streams are captured).
        let versionCommand = SSHCommand(executableURL: sshExecutable, arguments: ["-V"])
        let version = (try? await SSHProcess.runCapturingBothStreams(versionCommand))
            ?? SSHCommandResult(terminationStatus: -1, errorText: "")
        // `ssh -V` prints to stderr and exits 0.
        let versionText = version.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.terminationStatus == 0, versionText.lowercased().hasPrefix("openssh") {
            findings.append(DoctorFinding(
                layer: .system,
                severity: .ok,
                check: "openssh",
                detail: versionText
            ))
        } else {
            findings.append(DoctorFinding(
                layer: .system,
                severity: .fail,
                check: "openssh",
                detail: versionText.isEmpty
                    ? "\(sshExecutable.path) did not run (exit \(version.terminationStatus))"
                    : versionText,
                suggestion: "Install OpenSSH (macOS ships it at /usr/bin/ssh; on Linux install the openssh-client package)."
            ))
        }

        // Secret store resolution
        do {
            _ = try secretStoreResolver()
            findings.append(DoctorFinding(
                layer: .system,
                severity: .ok,
                check: "secret-store",
                detail: SecretStoreResolver.backendDescription
            ))
        } catch {
            findings.append(DoctorFinding(
                layer: .system,
                severity: .fail,
                check: "secret-store",
                detail: error.localizedDescription,
                suggestion: "Enable a secret backend before storing API keys (macOS: Keychain; Linux: MODELMOOR_SECRET_BACKEND=file)."
            ))
        }

        // Runtime directory writability
        let runtimeDirectory = profile.runtimeDirectoryURL
        do {
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            findings.append(DoctorFinding(
                layer: .system,
                severity: .ok,
                check: "runtime-directory",
                detail: "runtime locks under \(runtimeDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
            ))
        } catch {
            findings.append(DoctorFinding(
                layer: .system,
                severity: .fail,
                check: "runtime-directory",
                detail: error.localizedDescription,
                suggestion: "Make the runtime directory writable by the current user."
            ))
        }
    }

    private func checkSSHSyntax(
        configuration: ModelMoorConfiguration,
        findings: inout [DoctorFinding]
    ) async {
        for tunnel in configuration.tunnels {
            let command = SSHCommand(
                executableURL: sshExecutable,
                arguments: ["-G", tunnel.sshHost]
            )
            let result = await Self.runSSH(command)
            if result.terminationStatus == 0 {
                findings.append(DoctorFinding(
                    layer: .sshTransport,
                    severity: .ok,
                    check: "ssh-config \(tunnel.name)",
                    detail: "ssh -G resolves \(tunnel.sshHost)"
                ))
            } else {
                findings.append(DoctorFinding(
                    layer: .sshTransport,
                    severity: .fail,
                    check: "ssh-config \(tunnel.name)",
                    detail: result.errorText.isEmpty
                        ? "ssh -G exited with code \(result.terminationStatus)"
                        : result.errorText,
                    suggestion: "Check the Host entry for \(tunnel.sshHost) in ~/.ssh/config."
                ))
            }
        }
    }

    private func checkSSHTransport(
        configuration: ModelMoorConfiguration,
        findings: inout [DoctorFinding]
    ) async {
        for tunnel in configuration.tunnels where tunnel.connectOnLaunch {
            let result = await batchModeProbe(tunnel.sshHost)
            if result.status == 0 {
                findings.append(DoctorFinding(
                    layer: .sshTransport,
                    severity: .ok,
                    check: "ssh-connect \(tunnel.name)",
                    detail: "BatchMode probe to \(tunnel.sshHost) succeeded"
                ))
            } else {
                findings.append(DoctorFinding(
                    layer: .sshTransport,
                    severity: .fail,
                    check: "ssh-connect \(tunnel.name)",
                    detail: result.stderr.isEmpty
                        ? "ssh exited with code \(result.status)"
                        : result.stderr,
                    suggestion: "Run `ssh \(tunnel.sshHost) true` interactively to fix authentication or host keys; BatchMode never prompts."
                ))
            }
        }
    }

    private func checkLocalPorts(
        configuration: ModelMoorConfiguration,
        findings: inout [DoctorFinding]
    ) async {
        for tunnel in configuration.tunnels {
            do {
                try TunnelService.systemLocalPortPreflight(for: tunnel)
                for mapping in tunnel.enabledMappings where mapping.direction.listensLocally {
                    findings.append(DoctorFinding(
                        layer: .sshTransport,
                        severity: .ok,
                        check: "local-port \(mapping.listenPort)",
                        detail: "127.0.0.1:\(mapping.listenPort) is free for \(tunnel.name)"
                    ))
                }
            } catch let failure as TunnelPreflightFailure {
                findings.append(DoctorFinding(
                    layer: .sshTransport,
                    severity: .fail,
                    check: "local-port \(tunnel.name)",
                    detail: failure.detail,
                    suggestion: "Choose another local listen port or stop the existing listener."
                ))
            } catch {
                findings.append(DoctorFinding(
                    layer: .sshTransport,
                    severity: .fail,
                    check: "local-port \(tunnel.name)",
                    detail: error.localizedDescription
                ))
            }
        }
    }

    private func checkEndpoints(
        configuration: ModelMoorConfiguration,
        findings: inout [DoctorFinding]
    ) async {
        let mappings = Dictionary(
            uniqueKeysWithValues: configuration.tunnels.flatMap(\.mappings).map { ($0.id, $0) }
        )
        let secretStore = try? secretStoreResolver()
        for endpoint in configuration.endpoints where endpoint.enabled {
            var secret: String?
            if let keyID = endpoint.activeAPIKeyID, let secretStore {
                secret = try? secretStore.token(for: keyID)
            }
            let inspection = await inspector.inspect(endpoint, mappings: mappings, secret: secret)
            let name = "endpoint \(endpoint.name)"
            if let code = inspection.statusCode, code == 401 || code == 403 {
                findings.append(DoctorFinding(
                    layer: .endpointAuth,
                    severity: .fail,
                    check: name,
                    detail: "Authentication required (HTTP \(code))",
                    suggestion: "Store a valid API key for this endpoint (GUI endpoint editor or `modelmoor probe`)."
                ))
            } else if inspection.errorMessage != nil && !inspection.isReachable {
                findings.append(DoctorFinding(
                    layer: .sshTransport,
                    severity: .fail,
                    check: name,
                    detail: inspection.errorMessage ?? "unreachable",
                    suggestion: "Check that the tunnel is connected and the remote service is running."
                ))
            } else if inspection.models == nil && endpoint.modelListPath != nil {
                findings.append(DoctorFinding(
                    layer: .apiProtocol,
                    severity: .fail,
                    check: name,
                    detail: inspection.errorMessage ?? "Model list did not decode",
                    suggestion: "The endpoint must expose an OpenAI-compatible /models list or be marked as custom HTTP."
                ))
            } else {
                findings.append(DoctorFinding(
                    layer: .apiProtocol,
                    severity: .ok,
                    check: name,
                    detail: inspection.models.map { "\($0.count) model(s)" }
                        ?? "reachable (\(inspection.statusCode.map(String.init) ?? "?"))"
                ))
            }
        }
    }

    private func checkGateway(
        configuration: ModelMoorConfiguration,
        findings: inout [DoctorFinding]
    ) async {
        guard configuration.gateway.enabled else {
            findings.append(DoctorFinding(
                layer: .gateway,
                severity: .ok,
                check: "gateway",
                detail: "Unified API is disabled"
            ))
            return
        }
        let port = configuration.gateway.listenPort
        // If a runtime owns the loopback listener, probe it; otherwise check
        // that the configured port is bindable.
        if let response = await probeGateway(port: port, requiresAPIKey: configuration.gateway.requiresAPIKey) {
            findings.append(response)
            return
        }
        let probe = TunnelConfiguration(
            name: "doctor-gateway-probe",
            sshHost: "localhost",
            mappings: [PortMappingConfiguration(
                name: "probe",
                direction: .local,
                listenPort: port,
                destinationHost: "127.0.0.1",
                destinationPort: 1
            )]
        )
        do {
            try TunnelService.systemLocalPortPreflight(for: probe)
            findings.append(DoctorFinding(
                layer: .gateway,
                severity: .ok,
                check: "gateway",
                detail: "127.0.0.1:\(port) is free for the Unified API (not currently running)"
            ))
        } catch {
            findings.append(DoctorFinding(
                layer: .gateway,
                severity: .fail,
                check: "gateway",
                detail: "127.0.0.1:\(port) is unavailable and no healthy Unified API answered",
                suggestion: "Stop the process occupying the port or pick another listen port."
            ))
        }
    }

    /// Probes a possibly-running Unified API. A 401/200 proves liveness;
    /// returns nil when nothing answers on the port.
    private func probeGateway(port: Int, requiresAPIKey: Bool) async -> DoctorFinding? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 401 && requiresAPIKey {
                return DoctorFinding(
                    layer: .gateway,
                    severity: .ok,
                    check: "gateway",
                    detail: "Unified API is running on 127.0.0.1:\(port) and enforcing API keys"
                )
            }
            if (200...299).contains(http.statusCode) {
                return DoctorFinding(
                    layer: .gateway,
                    severity: requiresAPIKey ? .fail : .ok,
                    check: "gateway",
                    detail: requiresAPIKey
                        ? "Unified API answered without an API key while keys are required"
                        : "Unified API is running on 127.0.0.1:\(port)",
                    suggestion: requiresAPIKey
                        ? "Restart the runtime so the listener picks up the API key configuration."
                        : nil
                )
            }
            return DoctorFinding(
                layer: .gateway,
                severity: .warn,
                check: "gateway",
                detail: "Something answers on 127.0.0.1:\(port) with HTTP \(http.statusCode)"
            )
        } catch {
            return nil
        }
    }

    private static func runSSH(_ command: SSHCommand) async -> SSHCommandResult {
        (try? await SSHProcess.run(command))
            ?? SSHCommandResult(terminationStatus: -1, errorText: "could not launch ssh")
    }
}
