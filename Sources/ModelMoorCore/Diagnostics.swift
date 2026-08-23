import Foundation

public enum DiagnosticSubjectKind: String, Codable, CaseIterable, Sendable {
    case system
    case mooring
    case endpoint
    case gateway
}

public struct DiagnosticSubject: Hashable, Codable, Sendable {
    public var kind: DiagnosticSubjectKind
    public var identifier: String

    public init(kind: DiagnosticSubjectKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }

    public static func mooring(_ id: UUID) -> Self { Self(kind: .mooring, identifier: id.uuidString) }
    public static func endpoint(_ id: UUID) -> Self { Self(kind: .endpoint, identifier: id.uuidString) }
    public static let gateway = Self(kind: .gateway, identifier: "local-gateway")
    public static let system = Self(kind: .system, identifier: "local-system")
}

public enum DiagnosticSeverity: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var subject: DiagnosticSubject
    public var severity: DiagnosticSeverity
    public var category: String
    public var summary: String

    public init(
        timestamp: Date = Date(),
        subject: DiagnosticSubject,
        severity: DiagnosticSeverity,
        category: String,
        summary: String
    ) {
        self.timestamp = timestamp
        self.subject = subject
        self.severity = severity
        self.category = category
        self.summary = summary
    }
}

public actor DiagnosticLog {
    public let capacityPerSubject: Int
    private let homeDirectory: String
    private var eventsBySubject: [DiagnosticSubject: [DiagnosticEvent]] = [:]

    public init(
        capacityPerSubject: Int = 200,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.capacityPerSubject = max(1, capacityPerSubject)
        self.homeDirectory = homeDirectory
    }

    public func append(
        subject: DiagnosticSubject,
        severity: DiagnosticSeverity,
        category: String,
        summary: String,
        secrets: [String] = [],
        timestamp: Date = Date()
    ) {
        let safeEvent = DiagnosticEvent(
            timestamp: timestamp,
            subject: subject,
            severity: severity,
            category: Self.redact(category, homeDirectory: homeDirectory, secrets: secrets, limit: 80),
            summary: Self.redact(summary, homeDirectory: homeDirectory, secrets: secrets, limit: 500)
        )
        var events = eventsBySubject[subject, default: []]
        events.append(safeEvent)
        if events.count > capacityPerSubject {
            events.removeFirst(events.count - capacityPerSubject)
        }
        eventsBySubject[subject] = events
    }

    public func events(for subject: DiagnosticSubject) -> [DiagnosticEvent] {
        eventsBySubject[subject, default: []]
    }

    public func removeEvents(for subject: DiagnosticSubject) {
        eventsBySubject[subject] = nil
    }

    public func summary() -> String {
        let formatter = ISO8601DateFormatter()
        return eventsBySubject.values
            .flatMap { $0 }
            .sorted { $0.timestamp < $1.timestamp }
            .map { event in
                let shortIdentifier = String(event.subject.identifier.prefix(12))
                return "\(formatter.string(from: event.timestamp)) [\(event.subject.kind.rawValue):\(shortIdentifier)] [\(event.severity.rawValue)] \(event.category): \(event.summary)"
            }
            .joined(separator: "\n")
    }

    static func redact(
        _ source: String,
        homeDirectory: String,
        secrets: [String],
        limit: Int
    ) -> String {
        var result = source.replacingOccurrences(of: homeDirectory, with: "~")
        for secret in secrets.filter({ $0.count >= 4 }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }
        let patterns = [
            #"(?i)\b(Bearer\s+)[^\s,;]+"#,
            #"(?i)\b((?:authorization|api[_-]?key|token|secret|password)\s*[:=]\s*)[^\s,;]+"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1<redacted>"
            )
        }
        result = result.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard result.count > limit else { return result }
        return String(result.prefix(max(0, limit - 1))) + "…"
    }
}
