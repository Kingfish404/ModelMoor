import Foundation
import ModelMoorCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owner-only JSON secret backend, selected by `SecretStoreResolver`.
public struct HeadlessFileSecretStore: Sendable, ModelMoorSecretStore {
    private struct Envelope: Codable {
        var schemaVersion: Int = 1
        var secrets: [String: String] = [:]
    }

    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func token(account: String) throws -> String? {
        try lock.withLock {
            try loadUnlocked().secrets[account]
        }
    }

    public func setToken(_ token: String?, account: String) throws {
        try update { envelope in
            let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            envelope.secrets[account] = trimmed.isEmpty ? nil : trimmed
        }
    }

    private func update(_ mutate: (inout Envelope) throws -> Void) throws {
        try lock.withLock {
            try prepareDirectory()
            let descriptor = open(fileURL.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                throw SecretStoreError.unavailable("Could not open the secrets file lock.")
            }
            defer { close(descriptor) }
            var attributes = stat()
            guard fstat(descriptor, &attributes) == 0,
                  attributes.st_uid == getuid(),
                  attributes.st_mode & S_IFMT == S_IFREG,
                  fchmod(descriptor, 0o600) == 0,
                  flock(descriptor, LOCK_EX) == 0 else {
                throw SecretStoreError.permissionDenied("Could not acquire a private secrets file lock.")
            }
            defer { flock(descriptor, LOCK_UN) }
            var envelope = try loadUnlocked()
            try mutate(&envelope)
            try saveUnlocked(envelope)
        }
    }

    private func loadUnlocked() throws -> Envelope {
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try manager.attributesOfItem(atPath: fileURL.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Envelope()
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SecretStoreError.permissionDenied("The secrets file must be a regular file, not a symbolic link: \(fileURL.path).")
        }
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw SecretStoreError.permissionDenied(
                "The secrets file is not owned by the current user: \(fileURL.path). Fix ownership or delete the file and re-create it."
            )
        }
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o777 == 0o600 else {
            throw SecretStoreError.permissionDenied(
                "The secrets file must have mode 0600: \(fileURL.path). Run `chmod 600` on it or delete the file and let ModelMoor re-create it."
            )
        }

        let data = try Data(contentsOf: fileURL)
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schemaVersion == 1 else {
                throw SecretStoreError.unavailable(
                    "The secrets file uses an unsupported schema version \(envelope.schemaVersion)."
                )
            }
            return envelope
        } catch let error as SecretStoreError {
            throw error
        } catch {
            throw SecretStoreError.unavailable(
                "The secrets file is unreadable: \(error.localizedDescription)"
            )
        }
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw SecretStoreError.permissionDenied("The secrets directory must be owned by the current user and must not be a symbolic link.")
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func saveUnlocked(_ envelope: Envelope) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(envelope)
            try DurableAtomicWriter.writeAtomically(data, to: fileURL, replacing: true)
        } catch {
            throw SecretStoreError.unavailable(
                "Could not write the secrets file: \(error.localizedDescription)"
            )
        }
    }
}
