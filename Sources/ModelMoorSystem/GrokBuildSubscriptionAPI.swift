// Grok subscription execution follows xAI's documented Grok Build headless
// interface. The user's normal Grok profile is never read or changed.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GrokBuildSubscriptionCredential: Equatable, Sendable {
    public let email: String
    /// Complete auth.json payload issued by `grok login`, kept by the caller
    /// in ModelMoor's secret store and materialized only in a private temp home.
    public let authFile: Data

    public init(email: String, authFile: Data) {
        self.email = email
        self.authFile = authFile
    }

    public init?(storedOAuthCredential: SubscriptionOAuthCredential) {
        guard let authFile = Data(base64Encoded: storedOAuthCredential.refreshToken),
              let parsed = try? GrokBuildSubscriptionAPIAdapter.credential(from: authFile) else { return nil }
        self = parsed
    }

    /// The existing vault stores this value encrypted. `refreshToken` carries
    /// the CLI auth document because Grok rotates the token pair as a unit.
    public var storedOAuthCredential: SubscriptionOAuthCredential {
        SubscriptionOAuthCredential(
            accessToken: Self.accessToken(in: authFile) ?? "",
            refreshToken: authFile.base64EncodedString()
        )
    }

    private static func accessToken(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return nil }
        return object.values.compactMap { $0["key"] as? String }.first
    }
}

public struct GrokBuildSubscriptionCompletion: Equatable, Sendable {
    public let body: Data
    public let inputTokens: Int64?
    public let outputTokens: Int64?
    public let updatedCredential: GrokBuildSubscriptionCredential?

    public init(
        body: Data,
        inputTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        updatedCredential: GrokBuildSubscriptionCredential? = nil
    ) {
        self.body = body
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.updatedCredential = updatedCredential
    }
}

public enum GrokBuildSubscriptionError: LocalizedError, Equatable {
    case executableMissing
    case unsupportedRequest(String)
    case unsupportedTools
    case unsupportedContent
    case invalidRequest
    case invalidCredential
    case launchFailed
    case processFailed(Int32)
    case invalidResponse
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .executableMissing:
            "Grok Build CLI is required for native Grok subscription routing. Install it or use another provider."
        case let .unsupportedRequest(path):
            "Grok subscription routing does not support POST \(path). Use /v1/chat/completions."
        case .unsupportedTools:
            "Grok subscription routing currently supports text-only requests without caller tools."
        case .unsupportedContent:
            "Grok subscription routing currently supports text-only message content."
        case .invalidRequest:
            "The Grok subscription request is missing valid messages."
        case .invalidCredential:
            "The ModelMoor-managed Grok sign-in is unavailable or incomplete."
        case .launchFailed:
            "Could not start Grok Build for the subscription request."
        case let .processFailed(status):
            "Grok Build exited with status \(status). Check the subscription login and model name."
        case .invalidResponse:
            "Grok Build returned an unreadable response."
        case .cancelled:
            "The Grok subscription request was cancelled."
        }
    }
}

/// Runs the genuine Grok Build CLI in headless mode in an empty, private
/// workspace. It disables built-in tools, subagents and web search, and uses
/// an empty temporary Grok home so user memory, settings and sessions cannot
/// be read or changed.
public struct GrokBuildSubscriptionAPIAdapter: Sendable {
    public static let models = [SubscriptionModel(id: "grok/grok-4.7", name: "Grok 4.7")]

    public let executableURL: URL?
    public let timeout: Duration

    public init(
        executableURL: URL? = Self.findExecutable(),
        timeout: Duration = .seconds(300)
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public static func credential(from authFile: Data) throws -> GrokBuildSubscriptionCredential {
        guard let object = try? JSONSerialization.jsonObject(with: authFile) as? [String: [String: Any]],
              let entry = object.values.first(where: { ($0["key"] as? String)?.isEmpty == false }),
              let email = entry["email"] as? String, !email.isEmpty else {
            throw GrokBuildSubscriptionError.invalidCredential
        }
        return GrokBuildSubscriptionCredential(email: email, authFile: authFile)
    }

    public func complete(
        _ request: SubscriptionAPIRequest,
        credential: GrokBuildSubscriptionCredential,
        upstreamModel: String
    ) async throws -> GrokBuildSubscriptionCompletion {
        guard let executableURL else { throw GrokBuildSubscriptionError.executableMissing }
        guard request.method.uppercased() == "POST" else {
            throw GrokBuildSubscriptionError.unsupportedRequest(request.pathAndQuery)
        }
        let path = URLComponents(string: request.pathAndQuery)?.path ?? request.pathAndQuery
        guard path == "/v1/chat/completions" else {
            throw GrokBuildSubscriptionError.unsupportedRequest(path)
        }
        guard Self.validAuthFile(credential.authFile), !upstreamModel.isEmpty else {
            throw GrokBuildSubscriptionError.invalidCredential
        }
        let prompt = try Self.prompt(from: request.body)
        let runner = GrokBuildProcessRunner()
        let timeout = self.timeout
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try runner.run(
                    executableURL: executableURL,
                    model: Self.modelName(upstreamModel),
                    authFile: credential.authFile,
                    prompt: prompt,
                    timeout: timeout
                )
            }.value
        } onCancel: {
            runner.terminate()
        }
    }

    public static func findExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path
        let candidates = paths + [
            URL(fileURLWithPath: home).appendingPathComponent(".grok/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"
        ]
        var seen = Set<String>()
        for directory in candidates where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("grok")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func modelName(_ model: String) -> String {
        model.hasPrefix("grok/") ? String(model.dropFirst("grok/".count)) : model
    }

    private static func validAuthFile(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return false }
        return object.values.contains { ($0["key"] as? String)?.isEmpty == false }
    }

    private static func prompt(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]], !messages.isEmpty else {
            throw GrokBuildSubscriptionError.invalidRequest
        }
        if let tools = object["tools"] as? [Any], !tools.isEmpty { throw GrokBuildSubscriptionError.unsupportedTools }
        if let functions = object["functions"] as? [Any], !functions.isEmpty { throw GrokBuildSubscriptionError.unsupportedTools }
        var sections: [String] = []
        for message in messages {
            guard let role = message["role"] as? String, let content = message["content"] else {
                throw GrokBuildSubscriptionError.invalidRequest
            }
            if let calls = message["tool_calls"] as? [Any], !calls.isEmpty
                || message["function_call"] != nil || role == "tool" {
                throw GrokBuildSubscriptionError.unsupportedTools
            }
            let text = try Self.text(from: content)
            guard !text.isEmpty else { continue }
            switch role {
            case "system", "developer": sections.append("Context (\(role)):\n\(text)")
            case "assistant": sections.append("Assistant (previous response):\n\(text)")
            case "user": sections.append("User:\n\(text)")
            default: throw GrokBuildSubscriptionError.invalidRequest
            }
        }
        guard !sections.isEmpty else { throw GrokBuildSubscriptionError.invalidRequest }
        return sections.joined(separator: "\n\n")
    }

    private static func text(from value: Any) throws -> String {
        if let string = value as? String { return string }
        guard let parts = value as? [[String: Any]] else { throw GrokBuildSubscriptionError.unsupportedContent }
        var output = ""
        for part in parts {
            guard part["type"] as? String == "text", let text = part["text"] as? String else {
                throw GrokBuildSubscriptionError.unsupportedContent
            }
            output += text
        }
        return output
    }
}

private final class GrokBuildProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func terminate() {
        let process = lock.withLock { () -> Process? in
            cancelled = true
            return self.process
        }
        if let process, process.isRunning { process.terminate() }
    }

    func run(
        executableURL: URL,
        model: String,
        authFile: Data,
        prompt: String,
        timeout: Duration
    ) throws -> GrokBuildSubscriptionCompletion {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ModelMoor-Grok-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: root) }
        let grokHome = root.appendingPathComponent(".grok", isDirectory: true)
        try manager.createDirectory(at: grokHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try authFile.write(to: grokHome.appendingPathComponent("auth.json"), options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: grokHome.appendingPathComponent("auth.json").path)
        try Self.writeIsolatedGrokConfiguration(to: grokHome, fileManager: manager)
        let promptFile = root.appendingPathComponent("request.txt")
        try Data(prompt.utf8).write(to: promptFile, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptFile.path)

        let output = Pipe()
        let errors = Pipe()
        let command = Process()
        command.executableURL = executableURL
        command.arguments = [
            "--prompt-file", promptFile.path,
            "--output-format", "plain", "--model", model,
            "--tools", "", "--no-subagents", "--disable-web-search"
        ]
        command.currentDirectoryURL = root
        command.standardInput = FileHandle.nullDevice
        command.standardOutput = output
        command.standardError = errors
        var environment: [String: String] = [
            "HOME": root.path,
            "GROK_HOME": grokHome.path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_DATA_HOME": root.appendingPathComponent("data").path,
            "TMPDIR": root.path,
            "TERM": "dumb"
        ]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["PATH", "LANG", "LC_ALL"] {
            if let value = inherited[key] { environment[key] = value }
        }
        command.environment = environment
        guard !lock.withLock({ cancelled }) else { throw GrokBuildSubscriptionError.cancelled }
        do { try command.run() } catch { throw GrokBuildSubscriptionError.launchFailed }
        lock.withLock { process = command }
        defer { lock.withLock { process = nil } }
        if lock.withLock({ cancelled }) { command.terminate() }

        let outputBox = GrokBuildDataBox()
        let stderrBox = GrokBuildDataBox()
        let reads = DispatchGroup()
        reads.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputBox.set(Self.readBounded(output.fileHandleForReading, maximumBytes: 16 * 1_024 * 1_024))
            reads.leave()
        }
        reads.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.set(Self.readBounded(errors.fileHandleForReading, maximumBytes: 64 * 1_024))
            reads.leave()
        }
        let timeoutTask = Task.detached { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.terminate() }
        }
        command.waitUntilExit()
        timeoutTask.cancel()
        reads.wait()
        if lock.withLock({ cancelled }) { throw GrokBuildSubscriptionError.cancelled }
        guard command.terminationStatus == 0 else {
            _ = stderrBox.value
            throw GrokBuildSubscriptionError.processFailed(command.terminationStatus)
        }
        let answer = String(decoding: outputBox.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw GrokBuildSubscriptionError.invalidResponse }
        let responseBody = try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl-\(UUID().uuidString.lowercased())",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [["index": 0, "message": ["role": "assistant", "content": answer], "finish_reason": "stop"]]
        ])
        let authURL = grokHome.appendingPathComponent("auth.json")
        let updatedAuth = (try? Data(contentsOf: authURL)).flatMap { Self.validAuthFile($0) ? $0 : nil }
        return GrokBuildSubscriptionCompletion(
            body: responseBody,
            updatedCredential: updatedAuth.map {
                GrokBuildSubscriptionCredential(email: Self.email(in: $0) ?? "Grok account", authFile: $0)
            }
        )
    }

    private static func validAuthFile(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return false }
        return object.values.contains { ($0["key"] as? String)?.isEmpty == false }
    }

    private static func email(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return nil }
        return object.values.compactMap { $0["email"] as? String }.first
    }

    private static func readBounded(_ handle: FileHandle, maximumBytes: Int) -> Data {
        var result = Data()
        while let data = try? handle.read(upToCount: 8 * 1_024), !data.isEmpty {
            if result.count < maximumBytes { result.append(data.prefix(maximumBytes - result.count)) }
        }
        return result
    }

    private static func writeIsolatedGrokConfiguration(to home: URL, fileManager: FileManager) throws {
        let config = home.appendingPathComponent("config.toml")
        try Data("[cli]\nauto_update = false\n".utf8).write(to: config, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
    }
}

private final class GrokBuildDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ data: Data) { lock.withLock { self.data = data } }
    var value: Data { lock.withLock { data } }
}
