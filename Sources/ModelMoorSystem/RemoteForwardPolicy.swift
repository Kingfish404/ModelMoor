import Foundation

/// Matches OpenSSH PermitRemoteOpen: literal hosts/ports, with a whole-field
/// wildcard only. Names are not resolved before checking this policy.
struct RemoteForwardPolicy: Sendable {
    private let destinations: [String]

    init(effectiveConfiguration: String) throws {
        guard let line = effectiveConfiguration.split(separator: "\n").first(where: {
            $0.lowercased().hasPrefix("permitremoteopen ")
        }) else { throw PolicyError.unavailable }
        destinations = line.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
        guard !destinations.isEmpty else { throw PolicyError.unavailable }
    }

    func permits(host: String, port: Int) -> Bool {
        if destinations == ["any"] { return true }
        if destinations == ["none"] { return false }
        return destinations.contains { destination in
            guard let separator = destination.lastIndex(of: ":") else { return false }
            var allowedHost = String(destination[..<separator])
            if allowedHost.hasPrefix("["), allowedHost.hasSuffix("]") {
                allowedHost = String(allowedHost.dropFirst().dropLast())
            }
            let allowedPort = String(destination[destination.index(after: separator)...])
            return (allowedHost == "*" || allowedHost == host)
                && (allowedPort == "*" || Int(allowedPort) == port)
        }
    }

    enum PolicyError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Could not read SSH remote SOCKS destination restrictions." }
    }
}
