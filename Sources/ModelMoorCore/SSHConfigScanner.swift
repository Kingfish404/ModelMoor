import Darwin
import Foundation

public struct SSHHostTarget: Identifiable, Hashable, Sendable {
    public var alias: String
    public var sourcePath: String

    public var id: String { alias.lowercased() }

    public init(alias: String, sourcePath: String) {
        self.alias = alias
        self.sourcePath = sourcePath
    }

    public var sourceName: String {
        URL(fileURLWithPath: sourcePath).lastPathComponent
    }
}

public struct SSHConfigScanner: Sendable {
    public var rootConfigURL: URL

    public init(
        rootConfigURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    ) {
        self.rootConfigURL = rootConfigURL
    }

    public func discoverTargets() throws -> [SSHHostTarget] {
        var targets: [String: SSHHostTarget] = [:]
        var visited: Set<String> = []
        try scan(rootConfigURL, targets: &targets, visited: &visited)
        return targets.values.sorted {
            $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending
        }
    }

    private func scan(
        _ fileURL: URL,
        targets: inout [String: SSHHostTarget],
        visited: inout Set<String>
    ) throws {
        let normalizedURL = fileURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else { return }
        guard visited.insert(normalizedURL.path).inserted else { return }

        let contents = try String(contentsOf: normalizedURL, encoding: .utf8)
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let directive = parts.first?.lowercased() else { continue }

            if directive == "include" {
                for pattern in parts.dropFirst() {
                    for includedURL in expand(pattern: pattern, relativeTo: normalizedURL) {
                        try scan(includedURL, targets: &targets, visited: &visited)
                    }
                }
            } else if directive == "host" {
                for alias in parts.dropFirst() where isConcreteAlias(alias) {
                    let key = alias.lowercased()
                    if targets[key] == nil {
                        targets[key] = SSHHostTarget(alias: alias, sourcePath: normalizedURL.path)
                    }
                }
            }
        }
    }

    private func isConcreteAlias(_ alias: String) -> Bool {
        !alias.hasPrefix("!") && !alias.contains("*") && !alias.contains("?")
    }

    private func expand(pattern: String, relativeTo sourceURL: URL) -> [URL] {
        let expanded = NSString(string: pattern).expandingTildeInPath
        let absolutePath: String
        if expanded.hasPrefix("/") {
            absolutePath = expanded
        } else {
            absolutePath = sourceURL.deletingLastPathComponent()
                .appendingPathComponent(expanded).path
        }

        guard absolutePath.contains("*") || absolutePath.contains("?") else {
            return [URL(fileURLWithPath: absolutePath)]
        }

        let patternURL = URL(fileURLWithPath: absolutePath)
        let directoryURL = patternURL.deletingLastPathComponent()
        let filenamePattern = patternURL.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else {
            return []
        }
        return names
            .filter { fnmatch(filenamePattern, $0, 0) == 0 }
            .sorted()
            .map { directoryURL.appendingPathComponent($0) }
    }
}
