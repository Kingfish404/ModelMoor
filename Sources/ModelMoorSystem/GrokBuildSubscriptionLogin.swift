import Foundation

/// Runs xAI's documented device login with a ModelMoor-owned HOME/GROK_HOME.
/// The CLI auth file is imported into ModelMoor's secret store before its
/// temporary profile is removed.
public actor GrokBuildSubscriptionLoginCoordinator {
    private struct ActiveFlow {
        var login: SubscriptionOAuthLogin
        let rootURL: URL
        let runner: GrokBuildLoginProcessRunner
        var urlContinuation: AsyncThrowingStream<URL, Error>.Continuation?
    }

    private let vault: SubscriptionCredentialVault
    private let executableURL: URL?
    private var flows: [UUID: ActiveFlow] = [:]

    public init(vault: SubscriptionCredentialVault, executableURL: URL? = GrokBuildSubscriptionAPIAdapter.findExecutable()) {
        self.vault = vault
        self.executableURL = executableURL
    }

    public func start() async throws -> SubscriptionOAuthLogin {
        for id in Array(flows.keys) { await cancel(id) }
        guard let executableURL else { throw GrokBuildSubscriptionError.executableMissing }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelMoor-Grok-Login-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let grokHome = root.appendingPathComponent(".grok", isDirectory: true)
        try FileManager.default.createDirectory(at: grokHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("[cli]\nauto_update = false\n".utf8).write(to: grokHome.appendingPathComponent("config.toml"), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: grokHome.appendingPathComponent("config.toml").path
        )

        let runner = GrokBuildLoginProcessRunner()
        do {
            try runner.start(executableURL: executableURL, rootURL: root, grokHomeURL: grokHome)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        let id = UUID()
        let placeholderURL = URL(string: "https://x.ai/cli")!
        let login = SubscriptionOAuthLogin(id: id, provider: .xai, url: placeholderURL, createdAt: Date(), state: .waiting)
        let (urlStream, continuation) = AsyncThrowingStream<URL, Error>.makeStream()
        flows[id] = ActiveFlow(login: login, rootURL: root, runner: runner, urlContinuation: continuation)
        let coordinator = self
        Task.detached(priority: .userInitiated) {
            let result = runner.waitForExit { url in
                Task { await coordinator.publishURL(url, for: id) }
            }
            await coordinator.finish(id, result: result)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            await self?.failIfNoURL(id)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            await self?.expire(id)
        }

        for try await url in urlStream {
            guard var flow = flows[id] else { throw GrokBuildSubscriptionError.cancelled }
            flow.login = SubscriptionOAuthLogin(
                id: flow.login.id,
                provider: .xai,
                url: url,
                createdAt: flow.login.createdAt,
                state: flow.login.state
            )
            flows[id] = flow
            return flow.login
        }
        throw GrokBuildSubscriptionError.invalidResponse
    }

    public func status(_ id: UUID) -> SubscriptionOAuthLogin? {
        flows[id]?.login
    }

    public func cancel(_ id: UUID) async {
        guard var flow = flows[id], flow.login.state == .waiting else { return }
        flow.login = SubscriptionOAuthLogin(
            id: id,
            provider: .xai,
            url: flow.login.url,
            createdAt: flow.login.createdAt,
            state: .cancelled
        )
        flow.urlContinuation?.finish(throwing: GrokBuildSubscriptionError.cancelled)
        flow.urlContinuation = nil
        flow.runner.terminate()
        flows[id] = flow
    }

    private func publishURL(_ url: URL, for id: UUID) {
        guard var flow = flows[id], flow.login.state == .waiting else { return }
        flow.urlContinuation?.yield(url)
        flow.urlContinuation?.finish()
        flow.urlContinuation = nil
        flow.login = SubscriptionOAuthLogin(
            id: id,
            provider: .xai,
            url: url,
            createdAt: flow.login.createdAt,
            state: .waiting
        )
        flows[id] = flow
    }

    private func failIfNoURL(_ id: UUID) {
        guard var flow = flows[id], flow.login.state == .waiting,
              flow.urlContinuation != nil else { return }
        flow.login = SubscriptionOAuthLogin(
            id: id,
            provider: .xai,
            url: flow.login.url,
            createdAt: flow.login.createdAt,
            state: .failed("Grok Build did not print a device sign-in URL. Check the installed CLI.")
        )
        flow.urlContinuation?.finish(throwing: GrokBuildSubscriptionError.invalidResponse)
        flow.urlContinuation = nil
        flow.runner.terminate()
        flows[id] = flow
    }

    private func expire(_ id: UUID) {
        guard var flow = flows[id], flow.login.state == .waiting else { return }
        flow.login = SubscriptionOAuthLogin(
            id: id,
            provider: .xai,
            url: flow.login.url,
            createdAt: flow.login.createdAt,
            state: .failed("Grok Build sign-in timed out. Start it again.")
        )
        flow.runner.terminate()
        flows[id] = flow
    }

    private func finish(_ id: UUID, result: Result<Data, Error>) async {
        guard var flow = flows[id] else { return }
        if flow.login.state == .cancelled {
            try? FileManager.default.removeItem(at: flow.rootURL)
            return
        }
        if case .failed = flow.login.state {
            try? FileManager.default.removeItem(at: flow.rootURL)
            return
        }
        do {
            let authFile = try result.get()
            let credential = try GrokBuildSubscriptionAPIAdapter.credential(from: authFile)
            let oauthCredential = credential.storedOAuthCredential
            let account = try await vault.save(provider: .xai, user: credential.email, credential: oauthCredential)
            flow.login = SubscriptionOAuthLogin(
                id: id,
                provider: .xai,
                url: flow.login.url,
                createdAt: flow.login.createdAt,
                state: .completed(account: account)
            )
        } catch {
            flow.login = SubscriptionOAuthLogin(
                id: id,
                provider: .xai,
                url: flow.login.url,
                createdAt: flow.login.createdAt,
                state: .failed(error.localizedDescription)
            )
        }
        flow.urlContinuation?.finish(throwing: GrokBuildSubscriptionError.invalidResponse)
        flow.urlContinuation = nil
        flows[id] = flow
        try? FileManager.default.removeItem(at: flow.rootURL)
    }
}

private final class GrokBuildLoginProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var output: Pipe?
    private var rootURL: URL?
    private var stopped = false

    func start(executableURL: URL, rootURL: URL, grokHomeURL: URL) throws {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["login", "--device-auth"]
        process.currentDirectoryURL = rootURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = [
            "HOME": rootURL.path,
            "GROK_HOME": grokHomeURL.path,
            "XDG_CONFIG_HOME": rootURL.appendingPathComponent("config").path,
            "XDG_DATA_HOME": rootURL.appendingPathComponent("data").path,
            "TMPDIR": rootURL.path,
            "TERM": "dumb"
        ]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["PATH", "LANG", "LC_ALL", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"] {
            if let value = inherited[key] { environment[key] = value }
        }
        process.environment = environment
        do { try process.run() } catch { throw GrokBuildSubscriptionError.launchFailed }
        lock.withLock {
            self.process = process
            self.output = pipe
            self.rootURL = rootURL
        }
    }

    func terminate() {
        let process = lock.withLock { () -> Process? in
            stopped = true
            return self.process
        }
        if let process, process.isRunning { process.terminate() }
    }

    func waitForExit(onURL: @escaping @Sendable (URL) -> Void) -> Result<Data, Error> {
        guard let processAndPipe = lock.withLock({ () -> (Process, Pipe)? in
            guard let runningProcess = self.process, let outputPipe = self.output else { return nil }
            return (runningProcess, outputPipe)
        }) else { return .failure(GrokBuildSubscriptionError.launchFailed) }
        let (process, pipe) = processAndPipe
        var buffered = ""
        var deliveredURL = false
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            buffered += String(decoding: data, as: UTF8.self)
            if !deliveredURL, let url = Self.firstURL(in: buffered) {
                deliveredURL = true
                onURL(url)
            }
            if buffered.count > 16_384 { buffered = String(buffered.suffix(4_096)) }
        }
        process.waitUntilExit()
        if lock.withLock({ stopped }) { return .failure(GrokBuildSubscriptionError.cancelled) }
        guard process.terminationStatus == 0 else {
            return .failure(GrokBuildSubscriptionError.processFailed(process.terminationStatus))
        }
        guard let rootURL,
              let data = try? Data(contentsOf: rootURL.appendingPathComponent(".grok/auth.json")) else {
            return .failure(GrokBuildSubscriptionError.invalidCredential)
        }
        return .success(data)
    }

    private static func firstURL(in text: String) -> URL? {
        guard let range = text.range(of: #"https?://[^\s\]>)"']+"#, options: .regularExpression) else { return nil }
        var candidate = String(text[range])
        while let last = candidate.last, ".,;:!?".contains(last) { candidate.removeLast() }
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme, scheme == "https",
              components.host != nil else { return nil }
        return components.url
    }
}
