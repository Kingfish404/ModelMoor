import Darwin
import Foundation

public final class RuntimeOwnership: @unchecked Sendable {
    public let lockFileURL: URL
    private let fileDescriptor: Int32

    private init(lockFileURL: URL, fileDescriptor: Int32) {
        self.lockFileURL = lockFileURL
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    public static func acquire(
        lockFileURL: URL = URL(fileURLWithPath: "/tmp/modelmoor-\(getuid())", isDirectory: true)
            .appendingPathComponent("runtime-owner.lock"),
        owner: String = ProcessInfo.processInfo.processName
    ) throws -> RuntimeOwnership {
        let directory = lockFileURL.deletingLastPathComponent()
        try ensurePrivateDirectory(directory)

        let descriptor = open(lockFileURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RuntimeOwnershipError.unavailable(posixMessage()) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let currentOwner = readOwner(from: descriptor)
            close(descriptor)
            throw RuntimeOwnershipError.alreadyOwned(currentOwner)
        }

        fchmod(descriptor, 0o600)
        let identity = "pid=\(getpid()) owner=\(sanitize(owner))\n"
        guard ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) >= 0,
              identity.withCString({ pointer in Darwin.write(descriptor, pointer, strlen(pointer)) }) == identity.utf8.count,
              fsync(descriptor) == 0 else {
            let detail = posixMessage()
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw RuntimeOwnershipError.unavailable(detail)
        }
        return RuntimeOwnership(lockFileURL: lockFileURL, fileDescriptor: descriptor)
    }

    private static func ensurePrivateDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let attributes = try manager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw RuntimeOwnershipError.unavailable("runtime directory is not owned by the current user")
            }
        } else {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func readOwner(from descriptor: Int32) -> String? {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitize(_ value: String) -> String {
        String(value.filter { !$0.isNewline && !$0.isControlCharacter }.prefix(80))
    }

    private static func posixMessage() -> String { String(cString: strerror(errno)) }
}

public enum RuntimeOwnershipError: LocalizedError, Equatable {
    case alreadyOwned(String?)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .alreadyOwned(owner):
            if let owner, !owner.isEmpty {
                return "The tunnel runtime is already owned (\(owner)). Quit the other ModelMoor runtime and try again."
            }
            return "The tunnel runtime is already owned. Quit the other ModelMoor runtime and try again."
        case let .unavailable(detail):
            return "Could not acquire the tunnel runtime: \(detail)"
        }
    }
}

private extension Character {
    var isControlCharacter: Bool {
        unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) }
    }
}
