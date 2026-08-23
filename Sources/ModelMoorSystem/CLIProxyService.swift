import ModelMoorCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CLIProxyRuntimeState: Equatable, Sendable {
    case stopped
    case starting
    case running(port: Int)
    case failed(String)
}

/// Narrow runtime surface used by the Application layer. Keeping process
/// launching behind this protocol lets session tests exercise lifecycle and
/// retry semantics without starting the bundled helper.
public protocol CLIProxyServicing: Actor {
    var state: CLIProxyRuntimeState { get async }

    func start(
        configuration: CLIProxyConfiguration,
        apiKey: String,
        managementPassword: String
    ) async throws

    func stop() async
}

public enum CLIProxyServiceError: LocalizedError, Equatable {
    case binaryMissing
    case dataPreparation(String)
    case launch(String)
    case processExited(Int32)
    case startupTimedOut

    public var errorDescription: String? {
        switch self {
        case .binaryMissing:
            "The bundled CLIProxyAPI helper is missing. Rebuild ModelMoor or set MODELMOOR_CLIPROXY_BINARY for development."
        case let .dataPreparation(message):
            "Could not prepare CLIProxyAPI data: \(message)"
        case let .launch(message):
            "Could not launch CLIProxyAPI: \(message)"
        case let .processExited(status):
            "CLIProxyAPI exited during startup with status \(status)."
        case .startupTimedOut:
            "CLIProxyAPI did not become ready in time."
        }
    }
}

public actor CLIProxyService {
    public private(set) var state: CLIProxyRuntimeState = .stopped

    private let binaryURL: URL?
    private let dataDirectoryURL: URL
    private let session: URLSession
    private let stateHandler: @Sendable (CLIProxyRuntimeState) -> Void
    private var process: Process?

    public init(
        binaryURL: URL? = CLIProxyService.defaultBinaryURL(),
        dataDirectoryURL: URL = CLIProxyService.defaultDataDirectoryURL(),
        session: URLSession = .shared,
        stateHandler: @escaping @Sendable (CLIProxyRuntimeState) -> Void = { _ in }
    ) {
        self.binaryURL = binaryURL
        self.dataDirectoryURL = dataDirectoryURL
        self.session = session
        self.stateHandler = stateHandler
    }

    public func start(
        configuration: CLIProxyConfiguration,
        apiKey: String,
        managementPassword: String
    ) async throws {
        if case .running(port: configuration.listenPort) = state, process?.isRunning == true { return }
        await stop()
        setState(.starting)

        guard let binaryURL, FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            setState(.failed(CLIProxyServiceError.binaryMissing.localizedDescription))
            throw CLIProxyServiceError.binaryMissing
        }

        do {
            let paths: (config: URL, auth: URL)
            do {
                paths = try prepareDataDirectory(configuration: configuration, apiKey: apiKey)
            } catch {
                throw CLIProxyServiceError.dataPreparation(error.localizedDescription)
            }
            let replacement = Process()
            replacement.executableURL = binaryURL
            replacement.arguments = ["--config", paths.config.path]
            replacement.currentDirectoryURL = dataDirectoryURL
            var environment = ProcessInfo.processInfo.environment
            environment["MANAGEMENT_PASSWORD"] = managementPassword
            replacement.environment = environment
            replacement.standardOutput = FileHandle.nullDevice
            replacement.standardError = FileHandle.nullDevice
            replacement.terminationHandler = { [weak self] terminated in
                Task { await self?.processDidTerminate(terminated) }
            }
            do {
                try replacement.run()
            } catch {
                throw CLIProxyServiceError.launch(error.localizedDescription)
            }
            process = replacement

            let ready = await waitUntilReady(port: configuration.listenPort, apiKey: apiKey)
            guard ready else {
                if !replacement.isRunning {
                    throw CLIProxyServiceError.processExited(replacement.terminationStatus)
                }
                throw CLIProxyServiceError.startupTimedOut
            }
            setState(.running(port: configuration.listenPort))
        } catch {
            await stopProcess()
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    public func stop() async {
        await stopProcess()
        setState(.stopped)
    }

    public static func defaultBinaryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        executableURL: URL? = CommandLine.arguments.first.map(URL.init(fileURLWithPath:))
    ) -> URL? {
        if let override = environment["MODELMOOR_CLIPROXY_BINARY"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        #if os(macOS)
        if let bundled = bundle.url(forAuxiliaryExecutable: "CLIProxyAPI") { return bundled }
        let candidate = bundle.bundleURL.appendingPathComponent("Contents/MacOS/CLIProxyAPI")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        #endif
        if let executableURL {
            let sibling = executableURL.deletingLastPathComponent()
                .appendingPathComponent("CLIProxyAPI")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
            if let development = developmentBinaryURL(near: executableURL) { return development }
        }
        return nil
    }

    /// `swift run` and the standalone TUI are not app bundles, but both are
    /// commonly launched from this repository after the pinned helper has
    /// been fetched into `.build/vendor`. Restrict this fallback to an
    /// executable ancestor's own build tree, never a global PATH search.
    private static func developmentBinaryURL(near executableURL: URL) -> URL? {
        let manager = FileManager.default
        var directory = executableURL.deletingLastPathComponent().standardizedFileURL
        while directory.path != "/" {
            let vendor = directory.appendingPathComponent(".build/vendor/cliproxyapi", isDirectory: true)
            if let versions = try? manager.contentsOfDirectory(
                at: vendor,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for version in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                    guard let architectures = try? manager.contentsOfDirectory(
                        at: version,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ) else { continue }
                    for architecture in architectures.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                        let candidate = architecture.appendingPathComponent("cli-proxy-api")
                        if manager.isExecutableFile(atPath: candidate.path) { return candidate }
                    }
                }
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    public static func defaultDataDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["MODELMOOR_CLIPROXY_DATA"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        }
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ModelMoor/CLIProxyAPI", isDirectory: true)
        #else
        return PlatformPaths.dataHome(environment: environment)
            .appendingPathComponent("modelmoor/CLIProxyAPI", isDirectory: true)
        #endif
    }

    public static func renderedConfiguration(
        configuration: CLIProxyConfiguration,
        apiKey: String,
        authDirectoryURL: URL
    ) -> String {
        func yamlString(_ value: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let data = try? encoder.encode(value)
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        return """
        host: "127.0.0.1"
        port: \(configuration.listenPort)
        auth-dir: \(yamlString(authDirectoryURL.path))
        api-keys:
          - \(yamlString(apiKey))
        remote-management:
          allow-remote: false
          secret-key: ""
          disable-control-panel: true
        debug: false
        commercial-mode: false
        logging-to-file: false
        logs-max-total-size-mb: 0
        usage-statistics-enabled: false
        request-log: false
        request-retry: 0
        max-retry-interval: 0
        routing:
          strategy: "round-robin"
        streaming:
          keepalive-seconds: 15
          bootstrap-retries: 0
        """
    }

    private func prepareDataDirectory(
        configuration: CLIProxyConfiguration,
        apiKey: String
    ) throws -> (config: URL, auth: URL) {
        let manager = FileManager.default
        try manager.createDirectory(
            at: dataDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectoryURL.path)
        let auth = dataDirectoryURL.appendingPathComponent("auths", isDirectory: true)
        try manager.createDirectory(
            at: auth,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: auth.path)
        let config = dataDirectoryURL.appendingPathComponent("config.yaml")
        let rendered = Self.renderedConfiguration(
            configuration: configuration,
            apiKey: apiKey,
            authDirectoryURL: auth
        )
        try Data(rendered.utf8).write(to: config)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        return (config, auth)
    }

    private func waitUntilReady(port: Int, apiKey: String) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return false }
        for _ in 0..<50 {
            guard process?.isRunning == true else { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 0.5
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func stopProcess() async {
        guard let running = process else { return }
        process = nil
        running.terminationHandler = nil
        if running.isRunning { running.terminate() }
        for _ in 0..<20 where running.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if running.isRunning {
            kill(running.processIdentifier, SIGKILL)
            running.waitUntilExit()
        }
    }

    private func processDidTerminate(_ terminated: Process) {
        guard process === terminated else { return }
        process = nil
        if case .stopped = state { return }
        setState(.failed("CLIProxyAPI exited with status \(terminated.terminationStatus)."))
    }

    private func setState(_ replacement: CLIProxyRuntimeState) {
        state = replacement
        stateHandler(replacement)
    }
}

extension CLIProxyService: CLIProxyServicing {}
