import Foundation
import Darwin

public struct SSHCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }
}

public enum SSHControlOperation: String, Sendable {
    case check
    case forward
    case cancel
    case exit
}

public struct SSHCommandBuilder: Sendable {
    public var executableURL: URL
    public var controlDirectoryURL: URL

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        controlDirectoryURL: URL = URL(
            fileURLWithPath: "/tmp/modelmoor-\(getuid())",
            isDirectory: true
        )
    ) {
        self.executableURL = executableURL
        self.controlDirectoryURL = controlDirectoryURL
    }

    public func controlPath(for tunnel: TunnelConfiguration) -> String {
        let compactID = tunnel.id.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(20)
        return controlDirectoryURL
            .appendingPathComponent("\(compactID).sock", isDirectory: false)
            .path
    }

    public func command(for tunnel: TunnelConfiguration) -> SSHCommand {
        let arguments = [
            "-M",
            "-S", controlPath(for: tunnel),
            "-N",
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ClearAllForwardings=yes",
            "-o", "ControlPersist=no",
            "-o", "ConnectTimeout=\(tunnel.connectTimeoutSeconds)",
            "-o", "ServerAliveInterval=\(tunnel.keepAliveIntervalSeconds)",
            "-o", "ServerAliveCountMax=\(tunnel.keepAliveFailureCount)",
            tunnel.sshHost
        ]
        return SSHCommand(
            executableURL: executableURL,
            arguments: arguments
        )
    }

    public func controlCommand(
        _ operation: SSHControlOperation,
        for tunnel: TunnelConfiguration
    ) -> SSHCommand {
        var arguments = [
            "-F", "/dev/null",
            "-S", controlPath(for: tunnel),
            "-O", operation.rawValue
        ]
        if operation == .forward || operation == .cancel {
            for mapping in tunnel.enabledMappings {
                arguments.append(mapping.direction.sshFlag)
                arguments.append(mapping.forwardingSpecification)
            }
        }
        arguments.append(tunnel.sshHost)
        return SSHCommand(executableURL: executableURL, arguments: arguments)
    }
}
