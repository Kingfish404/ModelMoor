// Claude Code subscription execution follows yetone/magpie's MIT-licensed
// approach of invoking the genuine Claude Code CLI. See Support/Licenses/Magpie-LICENSE.txt.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ClaudeCodeSubscriptionCompletion: Equatable, Sendable {
    public let body: Data
    public let inputTokens: Int64?
    public let outputTokens: Int64?

    public init(body: Data, inputTokens: Int64? = nil, outputTokens: Int64? = nil) {
        self.body = body
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum ClaudeCodeSubscriptionError: LocalizedError, Equatable {
    case executableMissing
    case unsupportedRequest(String)
    case unsupportedTools
    case unsupportedContent
    case invalidRequest
    case launchFailed
    case processFailed(Int32)
    case invalidResponse
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .executableMissing:
            "Claude Code is required for native Claude subscription routing. Install it or use another provider."
        case let .unsupportedRequest(path):
            "Claude Code subscription routing does not support POST \(path). Use /v1/chat/completions."
        case .unsupportedTools:
            "Claude Code subscription routing currently supports text-only requests without caller tools."
        case .unsupportedContent:
            "Claude Code subscription routing currently supports text-only message content."
        case .invalidRequest:
            "The Claude subscription request is missing valid messages."
        case .launchFailed:
            "Could not start Claude Code for the subscription request."
        case let .processFailed(status):
            "Claude Code exited with status \(status). Check the subscription login and model name."
        case .invalidResponse:
            "Claude Code returned an unreadable response."
        case .cancelled:
            "The Claude Code subscription request was cancelled."
        }
    }
}

/// Runs Claude Code with a ModelMoor-owned OAuth token and isolated temporary
/// home/config directories. The caller's Claude profile, settings and MCP
/// servers are neither read nor changed; all Claude tools are disabled.
public struct ClaudeCodeSubscriptionAPIAdapter: Sendable {
    public static let models = [
        SubscriptionModel(id: "claude/sonnet", name: "Claude Sonnet"),
        SubscriptionModel(id: "claude/opus", name: "Claude Opus"),
        SubscriptionModel(id: "claude/haiku", name: "Claude Haiku")
    ]

    public let executableURL: URL?
    public let timeout: Duration

    public init(
        executableURL: URL? = Self.findExecutable(),
        timeout: Duration = .seconds(300)
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public func complete(
        _ request: SubscriptionAPIRequest,
        credential: SubscriptionOAuthCredential,
        upstreamModel: String
    ) async throws -> ClaudeCodeSubscriptionCompletion {
        guard let executableURL else { throw ClaudeCodeSubscriptionError.executableMissing }
        guard request.method.uppercased() == "POST" else {
            throw ClaudeCodeSubscriptionError.unsupportedRequest(request.pathAndQuery)
        }
        let path = URLComponents(string: request.pathAndQuery)?.path ?? request.pathAndQuery
        guard path == "/v1/chat/completions" else {
            throw ClaudeCodeSubscriptionError.unsupportedRequest(path)
        }
        guard !credential.accessToken.isEmpty, !upstreamModel.isEmpty else {
            throw ClaudeCodeSubscriptionError.invalidRequest
        }
        let prompt = try Self.prompt(from: request.body)
        let runner = ClaudeCodeProcessRunner()
        let resolvedExecutableURL = executableURL
        let timeout = self.timeout
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try runner.run(
                    executableURL: resolvedExecutableURL,
                    model: Self.modelName(upstreamModel),
                    upstreamModel: Self.modelName(upstreamModel),
                    oauthToken: credential.accessToken,
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
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = pathEntries + [
            URL(fileURLWithPath: home).appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"
        ]
        var seen = Set<String>()
        for directory in candidates where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("claude")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func modelName(_ model: String) -> String {
        model.hasPrefix("claude/") ? String(model.dropFirst("claude/".count)) : model
    }

    private static func prompt(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]], !messages.isEmpty else {
            throw ClaudeCodeSubscriptionError.invalidRequest
        }
        if let tools = object["tools"] as? [Any], !tools.isEmpty {
            throw ClaudeCodeSubscriptionError.unsupportedTools
        }
        if let functions = object["functions"] as? [Any], !functions.isEmpty {
            throw ClaudeCodeSubscriptionError.unsupportedTools
        }
        var sections: [String] = []
        for message in messages {
            guard let role = message["role"] as? String,
                  let content = message["content"] else {
                throw ClaudeCodeSubscriptionError.invalidRequest
            }
            if let calls = message["tool_calls"] as? [Any], !calls.isEmpty
                || message["function_call"] != nil || role == "tool" {
                throw ClaudeCodeSubscriptionError.unsupportedTools
            }
            let text = try Self.text(from: content)
            guard !text.isEmpty else { continue }
            if role == "system" || role == "developer" {
                sections.append("Context (\(role)):\n\(text)")
            } else if role == "assistant" {
                sections.append("Assistant (previous response):\n\(text)")
            } else if role == "user" {
                sections.append("User:\n\(text)")
            } else {
                throw ClaudeCodeSubscriptionError.invalidRequest
            }
        }
        guard !sections.isEmpty else { throw ClaudeCodeSubscriptionError.invalidRequest }
        return sections.joined(separator: "\n\n")
    }

    private static func text(from value: Any) throws -> String {
        if let string = value as? String { return string }
        guard let parts = value as? [[String: Any]] else {
            throw ClaudeCodeSubscriptionError.unsupportedContent
        }
        var text: [String] = []
        for part in parts {
            guard let type = part["type"] as? String, type == "text",
                  let value = part["text"] as? String else {
                throw ClaudeCodeSubscriptionError.unsupportedContent
            }
            text.append(value)
        }
        return text.joined()
    }
}

private final class ClaudeCodeProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func terminate(markCancelled: Bool = true) {
        let process = lock.withLock { () -> Process? in
            if markCancelled { cancelled = true }
            return self.process
        }
        if let process, process.isRunning { process.terminate() }
    }

    func run(
        executableURL: URL,
        model: String,
        upstreamModel: String,
        oauthToken: String,
        prompt: String,
        timeout: Duration
    ) throws -> ClaudeCodeSubscriptionCompletion {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ModelMoor-Claude-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: root) }
        let config = root.appendingPathComponent("config", isDirectory: true)
        try manager.createDirectory(at: config, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let command = Process()
        command.executableURL = executableURL
        command.arguments = [
            "-p", "--output-format", "json", "--model", model,
            "--tools", "", "--strict-mcp-config", "--setting-sources", "",
            "--no-session-persistence"
        ]
        command.currentDirectoryURL = root
        command.standardInput = input
        command.standardOutput = output
        command.standardError = errors
        var environment: [String: String] = [:]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["PATH", "LANG", "LC_ALL", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"] {
            if let value = inherited[key] { environment[key] = value }
        }
        environment["HOME"] = root.path
        environment["TMPDIR"] = root.path
        environment["CLAUDE_CONFIG_DIR"] = config.path
        environment["CLAUDE_CODE_OAUTH_TOKEN"] = oauthToken
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["ENABLE_CLAUDEAI_MCP_SERVERS"] = "0"
        environment["DISABLE_AUTO_COMPACT"] = "1"
        environment["ANTHROPIC_API_KEY"] = nil
        environment["ANTHROPIC_AUTH_TOKEN"] = nil
        environment["ANTHROPIC_BASE_URL"] = nil
        command.environment = environment

        let isCancelled = lock.withLock { cancelled }
        guard !isCancelled else { throw ClaudeCodeSubscriptionError.cancelled }
        do {
            try command.run()
        } catch {
            throw ClaudeCodeSubscriptionError.launchFailed
        }
        lock.withLock { process = command }
        defer { lock.withLock { process = nil } }
        if lock.withLock({ cancelled }) { command.terminate() }

        let readGroup = DispatchGroup()
        let stdout = ClaudeCodeDataBox()
        let stderr = ClaudeCodeDataBox()
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = Self.readBounded(output.fileHandleForReading, maximumBytes: 16 * 1_024 * 1_024)
            stdout.set(data)
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = Self.readBounded(errors.fileHandleForReading, maximumBytes: 64 * 1_024)
            stderr.set(data)
            readGroup.leave()
        }

        let timeoutTask = Task.detached { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.terminate(markCancelled: false) }
        }
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            timeoutTask.cancel()
            command.terminate()
            throw ClaudeCodeSubscriptionError.launchFailed
        }
        command.waitUntilExit()
        timeoutTask.cancel()
        readGroup.wait()
        if lock.withLock({ cancelled }) { throw ClaudeCodeSubscriptionError.cancelled }
        guard command.terminationStatus == 0 else {
            _ = stderr.value // Drain stderr without including arbitrary CLI output in diagnostics.
            throw ClaudeCodeSubscriptionError.processFailed(command.terminationStatus)
        }
        return try Self.decodeCompletion(stdout.value, model: upstreamModel)
    }

    private static func readBounded(_ handle: FileHandle, maximumBytes: Int) -> Data {
        var result = Data()
        while let data = try? handle.read(upToCount: 8 * 1_024), !data.isEmpty {
            if result.count < maximumBytes {
                result.append(data.prefix(maximumBytes - result.count))
            }
        }
        return result
    }

    private static func decodeCompletion(_ data: Data, model: String) throws -> ClaudeCodeSubscriptionCompletion {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["is_error"] as? Bool != true,
              let result = object["result"] as? String else {
            throw ClaudeCodeSubscriptionError.invalidResponse
        }
        let usage = object["usage"] as? [String: Any] ?? [:]
        let input = (usage["input_tokens"] as? NSNumber)?.int64Value
            ?? (usage["prompt_tokens"] as? NSNumber)?.int64Value
        let output = (usage["output_tokens"] as? NSNumber)?.int64Value
            ?? (usage["completion_tokens"] as? NSNumber)?.int64Value
        let body = try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl-\(UUID().uuidString.lowercased())",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [["index": 0, "message": ["role": "assistant", "content": result], "finish_reason": "stop"]],
            "usage": [
                "prompt_tokens": input ?? 0,
                "completion_tokens": output ?? 0,
                "total_tokens": (input ?? 0) + (output ?? 0)
            ]
        ])
        return ClaudeCodeSubscriptionCompletion(body: body, inputTokens: input, outputTokens: output)
    }
}

private final class ClaudeCodeDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ data: Data) {
        lock.withLock { self.data = data }
    }

    var value: Data {
        lock.withLock { data }
    }
}
