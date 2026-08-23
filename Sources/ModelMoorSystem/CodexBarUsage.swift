import ModelMoorCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public struct SubscriptionUsageWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    public let resetDescription: String?

    public var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

public struct SubscriptionUsageSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    public let accountEmail: String?
    public let loginMethod: String?
    public let source: String
    public let primary: SubscriptionUsageWindow?
    public let secondary: SubscriptionUsageWindow?
    public let updatedAt: Date?
    public let errorMessage: String?

    public var hasUsage: Bool { primary != nil || secondary != nil }

    public init(
        id: String,
        accountEmail: String? = nil,
        loginMethod: String? = nil,
        source: String,
        primary: SubscriptionUsageWindow? = nil,
        secondary: SubscriptionUsageWindow? = nil,
        updatedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.accountEmail = accountEmail
        self.loginMethod = loginMethod
        self.source = source
        self.primary = primary
        self.secondary = secondary
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
    }
}

public protocol SubscriptionUsageProviding: Sendable {
    var isAvailable: Bool { get }
    func usage(for accounts: [CLIProxyAccount]) async -> [SubscriptionUsageSnapshot]
}

public struct CodexBarUsageService: Sendable {
    public let authDirectoryURL: URL
    public let executableURL: URL?

    public init(
        authDirectoryURL: URL,
        executableURL: URL? = CodexBarUsageService.installedExecutableURL()
    ) {
        self.authDirectoryURL = authDirectoryURL
        self.executableURL = executableURL
    }

    public static func installedExecutableURL(fileManager: FileManager = .default) -> URL? {
        var candidates: [URL?] = [
            URL(fileURLWithPath: "/usr/local/bin/codexbar")
        ]
        #if os(macOS)
        candidates.insert(contentsOf: [
            Bundle.main.url(forAuxiliaryExecutable: "CodexBarCLI"),
            URL(fileURLWithPath: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codexbar")
        ], at: 0)
        #else
        candidates.insert(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/codexbar"),
            at: 0
        )
        #endif
        return candidates.compactMap { $0 }.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public func usage(for accounts: [CLIProxyAccount]) async -> [SubscriptionUsageSnapshot] {
        guard executableURL != nil else { return [] }
        var snapshots: [SubscriptionUsageSnapshot] = []
        for account in accounts where account.provider.lowercased() == "codex" {
            if Task.isCancelled { break }
            do {
                snapshots.append(try await usage(for: account))
            } catch {
                snapshots.append(
                    SubscriptionUsageSnapshot(
                        id: account.id,
                        accountEmail: account.email,
                        loginMethod: account.accountType,
                        source: "oauth",
                        primary: nil,
                        secondary: nil,
                        updatedAt: nil,
                        errorMessage: error.localizedDescription
                    )
                )
            }
        }
        return snapshots
    }

    public func usage(for account: CLIProxyAccount) async throws -> SubscriptionUsageSnapshot {
        guard let executableURL else { throw CodexBarUsageError.notInstalled }
        let credentialURL = try credentialURL(for: account)
        let credentialData = try Data(contentsOf: credentialURL)
        let authData = try Self.codexAuthData(fromCLIProxyCredential: credentialData)
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("modelmoor-codexbar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryHome,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: temporaryHome) }

        let authURL = temporaryHome.appendingPathComponent("auth.json")
        try authData.write(to: authURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

        let output = try await Self.runCodexBar(
            executableURL: executableURL,
            codexHomeURL: temporaryHome
        )
        return try Self.decodeUsage(output, account: account)
    }

    static func codexAuthData(fromCLIProxyCredential data: Data) throws -> Data {
        guard let source = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = source["access_token"] as? String,
              !accessToken.isEmpty else {
            throw CodexBarUsageError.invalidCredential
        }
        var tokens: [String: Any] = ["access_token": accessToken]
        for key in ["account_id", "id_token"] {
            if let value = source[key] as? String, !value.isEmpty { tokens[key] = value }
        }
        var auth: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": tokens
        ]
        if let lastRefresh = source["last_refresh"] as? String, !lastRefresh.isEmpty {
            auth["last_refresh"] = lastRefresh
        }
        return try JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys])
    }

    static func decodeUsage(_ data: Data, account: CLIProxyAccount) throws -> SubscriptionUsageSnapshot {
        let payloads = try JSONDecoder().decode([CodexBarPayload].self, from: data)
        guard let payload = payloads.first(where: { $0.provider == "codex" }) ?? payloads.first else {
            throw CodexBarUsageError.emptyResponse
        }
        guard let usage = payload.usage else {
            throw CodexBarUsageError.queryFailed(payload.error?.message ?? "CodexBar returned no usage data.")
        }
        return SubscriptionUsageSnapshot(
            id: account.id,
            accountEmail: usage.accountEmail ?? account.email,
            loginMethod: usage.loginMethod ?? account.accountType,
            source: payload.source ?? "oauth",
            primary: usage.primary?.value,
            secondary: usage.secondary?.value,
            updatedAt: Self.parseDate(usage.updatedAt),
            errorMessage: nil
        )
    }

    private func credentialURL(for account: CLIProxyAccount) throws -> URL {
        guard account.name == URL(fileURLWithPath: account.name).lastPathComponent,
              !account.name.contains("/"),
              !account.name.contains("\\") else {
            throw CodexBarUsageError.invalidCredentialPath
        }
        let resolvedDirectory = authDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = resolvedDirectory
            .appendingPathComponent(account.name, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.deletingLastPathComponent() == resolvedDirectory else {
            throw CodexBarUsageError.invalidCredentialPath
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw CodexBarUsageError.credentialUnavailable
        }
        return candidate
    }

    private static func runCodexBar(executableURL: URL, codexHomeURL: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = [
                "usage", "--provider", "codex", "--source", "oauth",
                "--format", "json", "--json-only", "--no-credits", "--no-color"
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = codexHomeURL.path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            try process.run()

            let deadline = Date().addingTimeInterval(25)
            do {
                while process.isRunning, Date() < deadline {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                if process.isRunning {
                    kill(process.processIdentifier, SIGTERM)
                    kill(process.processIdentifier, SIGKILL)
                }
                throw error
            }
            if process.isRunning {
                process.terminate()
                try await Task.sleep(for: .milliseconds(200))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw CodexBarUsageError.timedOut
            }
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                if !output.isEmpty { return output }
                throw CodexBarUsageError.queryFailed("CodexBar exited with status \(process.terminationStatus).")
            }
            guard !output.isEmpty else { throw CodexBarUsageError.emptyResponse }
            return output
        }.value
    }

    fileprivate static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFractionalSeconds.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

extension CodexBarUsageService: SubscriptionUsageProviding {
    public var isAvailable: Bool { executableURL != nil }
}

public enum CodexBarUsageError: LocalizedError, Equatable {
    case notInstalled
    case invalidCredential
    case invalidCredentialPath
    case credentialUnavailable
    case emptyResponse
    case timedOut
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "CodexBar is not installed."
        case .invalidCredential: "This account credential cannot be used to query Codex usage."
        case .invalidCredentialPath: "The account credential path is invalid."
        case .credentialUnavailable: "The account credential file is unavailable."
        case .emptyResponse: "CodexBar returned an empty usage response."
        case .timedOut: "CodexBar did not return usage within 25 seconds."
        case let .queryFailed(message): "CodexBar could not query usage: \(message)"
        }
    }
}

private struct CodexBarPayload: Decodable {
    let provider: String
    let source: String?
    let usage: CodexBarUsagePayload?
    let error: CodexBarErrorPayload?
}

private struct CodexBarUsagePayload: Decodable {
    let primary: CodexBarWindowPayload?
    let secondary: CodexBarWindowPayload?
    let loginMethod: String?
    let accountEmail: String?
    let updatedAt: String?
}

private struct CodexBarWindowPayload: Decodable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: String?
    let resetDescription: String?

    var value: SubscriptionUsageWindow {
        SubscriptionUsageWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: CodexBarUsageService.parseDate(resetsAt),
            resetDescription: resetDescription
        )
    }
}

private struct CodexBarErrorPayload: Decodable {
    let message: String

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            message = value
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
    }

    private enum CodingKeys: String, CodingKey {
        case message
    }
}
