// Kimi Code's managed account flow and isolated ACP runner.
import Foundation
import ModelMoorCore

public struct KimiCodeSubscriptionProfile: Codable, Equatable, Sendable {
    /// OAuth files under KIMI_CODE_HOME/credentials. Session, MCP and user
    /// instruction files are intentionally excluded.
    public var credentialFiles: [String: Data]
    public var accountLabel: String {
        for data in credentialFiles.values {
            guard let root = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let value = Self.firstEmail(in: root) { return value }
        }
        return "Kimi Code account"
    }

    public init(credentialFiles: [String: Data]) { self.credentialFiles = credentialFiles }

    public init?(storedOAuthCredential: SubscriptionOAuthCredential) {
        guard let data = Data(base64Encoded: storedOAuthCredential.refreshToken),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              !value.credentialFiles.isEmpty else { return nil }
        self = value
    }

    public var storedOAuthCredential: SubscriptionOAuthCredential {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return SubscriptionOAuthCredential(accessToken: "kimi-code-managed", refreshToken: data.base64EncodedString())
    }

    public static func read(from home: URL) throws -> Self {
        let directory = home.appendingPathComponent("credentials", isDirectory: true)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [String: Data] = [:]
        for url in urls where url.pathExtension == "json" && url.lastPathComponent != "mcp" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            files[url.lastPathComponent] = try Data(contentsOf: url)
        }
        guard !files.isEmpty else { throw KimiCodeSubscriptionError.invalidCredential }
        return Self(credentialFiles: files)
    }

    func materialize(in home: URL) throws {
        let directory = home.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, data) in credentialFiles {
            guard URL(fileURLWithPath: name).lastPathComponent == name, name.hasSuffix(".json") else {
                throw KimiCodeSubscriptionError.invalidCredential
            }
            let target = directory.appendingPathComponent(name)
            try data.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
    }

    private static func firstEmail(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, item) in dictionary where ["email", "email_address", "emailAddress"].contains(key) {
                if let text = item as? String, text.contains("@") { return text }
            }
            for item in dictionary.values { if let email = firstEmail(in: item) { return email } }
        } else if let array = value as? [Any] {
            for item in array { if let email = firstEmail(in: item) { return email } }
        }
        return nil
    }
}

public struct KimiCodeSubscriptionCompletion: Equatable, Sendable {
    public let body: Data
    public let updatedProfile: KimiCodeSubscriptionProfile?
}

public enum KimiCodeSubscriptionError: LocalizedError, Equatable {
    case executableMissing, launchFailed, processFailed(Int), protocolError, invalidRequest
    case invalidCredential, invalidResponse, unsupportedRequest(String), unsupportedTools, unsupportedContent, cancelled

    public var errorDescription: String? {
        switch self {
        case .executableMissing: "Install Kimi Code CLI to use a Kimi subscription in ModelMoor."
        case .launchFailed: "ModelMoor could not start Kimi Code CLI."
        case let .processFailed(code): "Kimi Code CLI failed with exit status \(code)."
        case .protocolError: "Kimi Code CLI returned an invalid Agent Client Protocol response."
        case .invalidRequest: "The Kimi subscription request is invalid."
        case .invalidCredential: "The ModelMoor Kimi Code credential is missing or invalid. Sign in again."
        case .invalidResponse: "Kimi Code CLI returned no assistant text."
        case let .unsupportedRequest(path): "Kimi Code subscription routing does not support \(path)."
        case .unsupportedTools: "Kimi Code subscription routing currently accepts text requests without caller-provided tools."
        case .unsupportedContent: "Kimi Code subscription routing currently accepts text-only messages."
        case .cancelled: "The Kimi Code request was cancelled."
        }
    }
}

public struct KimiCodeSubscriptionAPIAdapter: Sendable {
    public static let models = ["kimi/k3"]
    private let executableURL: URL?
    public init(executableURL: URL? = Self.findExecutable()) { self.executableURL = executableURL }

    public static func findExecutable(environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) -> URL? {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in paths + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("kimi")
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public func complete(request: SubscriptionAPIRequest, profile: KimiCodeSubscriptionProfile, upstreamModel: String) async throws -> KimiCodeSubscriptionCompletion {
        guard let executableURL else { throw KimiCodeSubscriptionError.executableMissing }
        let path = URLComponents(string: request.pathAndQuery)?.path ?? request.pathAndQuery
        guard request.method.uppercased() == "POST", path == "/v1/chat/completions" else { throw KimiCodeSubscriptionError.unsupportedRequest(path) }
        guard !profile.credentialFiles.isEmpty else { throw KimiCodeSubscriptionError.invalidCredential }
        let prompt = try Self.prompt(from: request.body)
        let runner = KimiACPProcessRunner()
        let timeout: TimeInterval = 300
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try runner.run(executableURL: executableURL, profile: profile, prompt: prompt, model: Self.modelName(upstreamModel), timeout: timeout)
            }.value
        } onCancel: { runner.terminate() }
    }

    private static func modelName(_ value: String) -> String {
        if value.hasPrefix("kimi/") || value.hasPrefix("kimi-") { return String(value.dropFirst(5)) }
        return value
    }

    private static func prompt(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]], !messages.isEmpty else { throw KimiCodeSubscriptionError.invalidRequest }
        if let tools = object["tools"] as? [Any], !tools.isEmpty { throw KimiCodeSubscriptionError.unsupportedTools }
        if let functions = object["functions"] as? [Any], !functions.isEmpty { throw KimiCodeSubscriptionError.unsupportedTools }
        var sections: [String] = []
        for message in messages {
            guard let role = message["role"] as? String, let content = message["content"] else { throw KimiCodeSubscriptionError.invalidRequest }
            if (message["tool_calls"] as? [Any])?.isEmpty == false || message["function_call"] != nil || role == "tool" { throw KimiCodeSubscriptionError.unsupportedTools }
            let text = try Self.text(from: content)
            guard !text.isEmpty else { continue }
            switch role {
            case "system", "developer": sections.append("Context (\(role)):\n\(text)")
            case "assistant": sections.append("Assistant (previous response):\n\(text)")
            case "user": sections.append("User:\n\(text)")
            default: throw KimiCodeSubscriptionError.invalidRequest
            }
        }
        guard !sections.isEmpty else { throw KimiCodeSubscriptionError.invalidRequest }
        return sections.joined(separator: "\n\n")
    }

    private static func text(from value: Any) throws -> String {
        if let string = value as? String { return string }
        guard let parts = value as? [[String: Any]] else { throw KimiCodeSubscriptionError.unsupportedContent }
        var output = ""
        for part in parts {
            guard part["type"] as? String == "text", let text = part["text"] as? String else { throw KimiCodeSubscriptionError.unsupportedContent }
            output += text
        }
        return output
    }
}

private final class KimiACPProcessRunner: @unchecked Sendable {
    private let lock = NSLock(); private var process: Process?; private var cancelled = false
    func terminate() { let p = lock.withLock { cancelled = true; return process }; if let p, p.isRunning { p.terminate() } }

    func run(executableURL: URL, profile: KimiCodeSubscriptionProfile, prompt: String, model: String, timeout: TimeInterval) throws -> KimiCodeSubscriptionCompletion {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ModelMoor-Kimi-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let dataHome = root.appendingPathComponent("kimi-code", isDirectory: true)
        let skills = root.appendingPathComponent("empty-skills", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: dataHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: skills, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try profile.materialize(in: dataHome)
        let alias = "modelmoor/\(model)"
        let config = """
        default_model = \"\(alias)\"
        telemetry = false
        \n[providers.\"managed:kimi-code\"]
        type = \"kimi\"
        base_url = \"https://api.kimi.com/coding/v1\"
        api_key = \"\"
        \n[models.\"\(alias)\"]
        provider = \"managed:kimi-code\"
        model = \"\(model)\"
        max_context_size = 1048576
        capabilities = []
        \n[tools]
        disabled = [\"*\"]
        \n[upgrade]
        auto_install = false
        """
        try Data(config.utf8).write(to: dataHome.appendingPathComponent("config.toml"), options: .atomic)
        try Data("{}".utf8).write(to: dataHome.appendingPathComponent("mcp.json"), options: .atomic)
        let output = Pipe(), input = Pipe(), child = Process()
        child.executableURL = executableURL; child.arguments = ["--skills-dir", skills.path, "acp"]; child.currentDirectoryURL = root
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        child.environment = ["HOME": home.path, "KIMI_CODE_HOME": dataHome.path, "KIMI_DISABLE_TELEMETRY": "1", "TMPDIR": root.path, "TERM": "dumb", "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        for key in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "LANG", "LC_ALL"] {
            if let value = ProcessInfo.processInfo.environment[key] { child.environment?[key] = value }
        }
        do { try child.run() } catch { throw KimiCodeSubscriptionError.launchFailed }
        lock.withLock { process = child; if cancelled { child.terminate() } }
        defer { if child.isRunning { child.terminate() } }
        let deadline = Date().addingTimeInterval(timeout)
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let process = self.lock.withLock { self.process }
            if let process, process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        defer { timeoutWork.cancel() }
        let writer = input.fileHandleForWriting, reader = output.fileHandleForReading
        func send(_ id: Int, _ method: String, _ params: [String: Any]) throws {
            var value: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
            guard JSONSerialization.isValidJSONObject(value), let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { throw KimiCodeSubscriptionError.protocolError }
            value.removeAll(keepingCapacity: false)
            try writer.write(contentsOf: bytes + Data([0x0a]))
        }
        func receive(until responseID: Int) throws -> [String: Any] {
            var buffer = Data()
            while Date() < deadline && !lock.withLock({ cancelled }) {
                let chunk = reader.availableData
                if chunk.isEmpty { throw KimiCodeSubscriptionError.protocolError }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0a) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if (message["id"] as? Int) == responseID {
                        if message["error"] != nil { throw KimiCodeSubscriptionError.protocolError }
                        return message["result"] as? [String: Any] ?? [:]
                    }
                }
            }
            if lock.withLock({ cancelled }) { throw KimiCodeSubscriptionError.cancelled }
            throw KimiCodeSubscriptionError.processFailed(-1)
        }
        let initialize: [String: Any] = ["protocolVersion": 1, "clientInfo": ["name": "ModelMoor", "version": "1"], "capabilities": [:]]
        try send(1, "initialize", initialize); _ = try receive(until: 1)
        try send(2, "session/new", ["cwd": root.path, "mcpServers": []]); let session = try receive(until: 2)
        guard let sessionID = session["sessionId"] as? String else { throw KimiCodeSubscriptionError.protocolError }
        try send(3, "session/prompt", ["sessionId": sessionID, "prompt": [["type": "text", "text": prompt]]])
        let result = try receivePrompt(until: 3, reader: reader, deadline: deadline)
        if lock.withLock({ cancelled }) { throw KimiCodeSubscriptionError.cancelled }
        let updated = try? KimiCodeSubscriptionProfile.read(from: dataHome)
        return KimiCodeSubscriptionCompletion(body: Self.response(text: result, model: model), updatedProfile: updated)
    }

    private func receivePrompt(until id: Int, reader: FileHandle, deadline: Date) throws -> String {
        var buffer = Data(), answer = ""
        while Date() < deadline && !lock.withLock({ cancelled }) {
            let chunk = reader.availableData
            if chunk.isEmpty { throw KimiCodeSubscriptionError.protocolError }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if let params = message["params"] as? [String: Any],
                   let update = params["update"] as? [String: Any], update["sessionUpdate"] as? String == "agent_message_chunk",
                   let content = update["content"] as? [String: Any], content["type"] as? String == "text" {
                    answer += content["text"] as? String ?? ""
                }
                if (message["id"] as? Int) == id {
                    guard !(message["error"] != nil), !answer.isEmpty else { throw KimiCodeSubscriptionError.invalidResponse }
                    return answer
                }
            }
        }
        if lock.withLock({ cancelled }) { throw KimiCodeSubscriptionError.cancelled }
        throw KimiCodeSubscriptionError.processFailed(-1)
    }

    private static func response(text: String, model: String) -> Data {
        let value: [String: Any] = ["id": "chatcmpl-modelmoor-kimi", "object": "chat.completion", "created": Int(Date().timeIntervalSince1970), "model": model, "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]]]
        return (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
    }
}

/// Performs Kimi's first-party managed-service device login in a private
/// KIMI_CODE_HOME. Only OAuth credential JSON files are imported into the
/// ModelMoor vault; sessions, skills, MCP declarations and agent instructions
/// are never retained.
public actor KimiCodeSubscriptionLoginCoordinator {
    private struct Flow {
        var login: SubscriptionOAuthLogin
        let root: URL
        let runner: KimiLoginProcessRunner
        var urlContinuation: AsyncThrowingStream<URL, Error>.Continuation?
    }
    private let vault: SubscriptionCredentialVault
    private let executableURL: URL?
    private var flows: [UUID: Flow] = [:]

    public init(vault: SubscriptionCredentialVault, executableURL: URL? = KimiCodeSubscriptionAPIAdapter.findExecutable()) {
        self.vault = vault; self.executableURL = executableURL
    }

    public func start() async throws -> SubscriptionOAuthLogin {
        for id in Array(flows.keys) { await cancel(id) }
        guard let executableURL else { throw KimiCodeSubscriptionError.executableMissing }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ModelMoor-Kimi-Login-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let dataHome = root.appendingPathComponent("kimi-code", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let runner = KimiLoginProcessRunner()
        do { try runner.start(executableURL: executableURL, root: root, home: home, dataHome: dataHome) }
        catch { try? FileManager.default.removeItem(at: root); throw error }
        let id = UUID()
        let placeholder = URL(string: "https://kimi.com/code")!
        let login = SubscriptionOAuthLogin(id: id, provider: .kimi, url: placeholder, createdAt: Date(), state: .waiting)
        let (stream, continuation) = AsyncThrowingStream<URL, Error>.makeStream()
        flows[id] = Flow(login: login, root: root, runner: runner, urlContinuation: continuation)
        let coordinator = self
        Task.detached(priority: .userInitiated) {
            let result = runner.waitForExit { url in Task { await coordinator.publish(url, id: id) } }
            await coordinator.finish(id, result: result)
        }
        Task { [weak self] in try? await Task.sleep(for: .seconds(30)); await self?.failIfNoURL(id) }
        Task { [weak self] in try? await Task.sleep(for: .seconds(600)); await self?.expire(id) }
        for try await url in stream {
            guard var flow = flows[id] else { throw KimiCodeSubscriptionError.cancelled }
            flow.login = SubscriptionOAuthLogin(id: id, provider: .kimi, url: url, createdAt: flow.login.createdAt, state: .waiting)
            flows[id] = flow
            return flow.login
        }
        throw KimiCodeSubscriptionError.invalidResponse
    }

    public func status(_ id: UUID) -> SubscriptionOAuthLogin? { flows[id]?.login }
    public func cancel(_ id: UUID) async {
        guard var flow = flows[id], flow.login.state == .waiting else { return }
        flow.login = SubscriptionOAuthLogin(id: id, provider: .kimi, url: flow.login.url, createdAt: flow.login.createdAt, state: .cancelled)
        flow.urlContinuation?.finish(throwing: KimiCodeSubscriptionError.cancelled); flow.urlContinuation = nil
        flow.runner.terminate(); flows[id] = flow
    }
    private func publish(_ url: URL, id: UUID) {
        guard var flow = flows[id], flow.login.state == .waiting else { return }
        flow.urlContinuation?.yield(url); flow.urlContinuation?.finish(); flow.urlContinuation = nil
        flow.login = SubscriptionOAuthLogin(id: id, provider: .kimi, url: url, createdAt: flow.login.createdAt, state: .waiting)
        flows[id] = flow
    }
    private func failIfNoURL(_ id: UUID) {
        guard var flow = flows[id], flow.login.state == .waiting, flow.urlContinuation != nil else { return }
        flow.login = SubscriptionOAuthLogin(id: id, provider: .kimi, url: flow.login.url, createdAt: flow.login.createdAt, state: .failed("Kimi Code did not print a device sign-in URL. Check the installed CLI."))
        flow.urlContinuation?.finish(throwing: KimiCodeSubscriptionError.protocolError); flow.urlContinuation = nil
        flow.runner.terminate(); flows[id] = flow
    }
    private func expire(_ id: UUID) {
        guard var flow = flows[id], flow.login.state == .waiting else { return }
        flow.login = SubscriptionOAuthLogin(id: id, provider: .kimi, url: flow.login.url, createdAt: flow.login.createdAt, state: .failed("Kimi Code sign-in timed out. Start it again."))
        flow.runner.terminate(); flows[id] = flow
    }
    private func finish(_ id: UUID, result: Result<KimiCodeSubscriptionProfile, Error>) async {
        guard var flow = flows[id] else { return }
        if flow.login.state == .cancelled { try? FileManager.default.removeItem(at: flow.root); return }
        if case .failed = flow.login.state { try? FileManager.default.removeItem(at: flow.root); return }
        do {
            let profile = try result.get()
            let account = try await vault.save(provider: .kimi, user: profile.accountLabel, credential: profile.storedOAuthCredential)
            flow.login = SubscriptionOAuthLogin(id: id, provider: .kimi, url: flow.login.url, createdAt: flow.login.createdAt, state: .completed(account: account))
        } catch {
            flow.login = SubscriptionOAuthLogin(id: id, provider: .kimi, url: flow.login.url, createdAt: flow.login.createdAt, state: .failed(error.localizedDescription))
        }
        flow.urlContinuation?.finish(throwing: KimiCodeSubscriptionError.protocolError); flow.urlContinuation = nil
        flows[id] = flow
        try? FileManager.default.removeItem(at: flow.root)
    }
}

private final class KimiLoginProcessRunner: @unchecked Sendable {
    private let lock = NSLock(); private var process: Process?; private var pipe: Pipe?; private var dataHome: URL?; private var stopped = false
    func start(executableURL: URL, root: URL, home: URL, dataHome: URL) throws {
        let pipe = Pipe(), process = Process()
        process.executableURL = executableURL; process.arguments = ["login", "--region", "global"]
        process.currentDirectoryURL = root; process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        var env = ["HOME": home.path, "KIMI_CODE_HOME": dataHome.path, "KIMI_DISABLE_TELEMETRY": "1", "TMPDIR": root.path, "TERM": "dumb"]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["PATH", "LANG", "LC_ALL", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"] { if let value = inherited[key] { env[key] = value } }
        process.environment = env
        do { try process.run() } catch { throw KimiCodeSubscriptionError.launchFailed }
        lock.withLock { self.process = process; self.pipe = pipe; self.dataHome = dataHome }
    }
    func terminate() { let process = lock.withLock { stopped = true; return self.process }; if let process, process.isRunning { process.terminate() } }
    func waitForExit(onURL: @escaping @Sendable (URL) -> Void) -> Result<KimiCodeSubscriptionProfile, Error> {
        guard let (process, pipe, dataHome) = lock.withLock({ () -> (Process, Pipe, URL)? in guard let process, let pipe, let dataHome else { return nil }; return (process, pipe, dataHome) }) else { return .failure(KimiCodeSubscriptionError.launchFailed) }
        var buffered = "", sentURL = false
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            buffered += String(decoding: data, as: UTF8.self)
            if !sentURL, let url = Self.findURL(in: buffered) { sentURL = true; onURL(url) }
            if buffered.count > 16_000 { buffered = String(buffered.suffix(4_000)) }
        }
        process.waitUntilExit()
        if lock.withLock({ stopped }) { return .failure(KimiCodeSubscriptionError.cancelled) }
        guard process.terminationStatus == 0 else { return .failure(KimiCodeSubscriptionError.processFailed(Int(process.terminationStatus))) }
        do { return .success(try KimiCodeSubscriptionProfile.read(from: dataHome)) } catch { return .failure(error) }
    }
    private static func findURL(in text: String) -> URL? {
        guard let range = text.range(of: #"https?://[^\s\]>)"']+"#, options: .regularExpression) else { return nil }
        var candidate = String(text[range]); while let last = candidate.last, ".,;:!?".contains(last) { candidate.removeLast() }
        guard let components = URLComponents(string: candidate), let scheme = components.scheme, ["http", "https"].contains(scheme), components.host != nil else { return nil }
        return URL(string: candidate)
    }
}
