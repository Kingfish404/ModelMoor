import Foundation
import ModelMoorCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Explicit opt-in secret backend for headless Linux: a single JSON file
/// with owner-only 0600 permissions under the XDG data directory. The file
/// is never created or read unless the user enabled this backend through
/// `SecretStoreResolver`; wrong owner or loose permissions are hard errors,
/// never a silent downgrade.
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
        try lock.withLock {
            var envelope = try loadUnlocked()
            let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                envelope.secrets[account] = nil
            } else {
                envelope.secrets[account] = trimmed
            }
            try saveUnlocked(envelope)
        }
    }

    private func loadUnlocked() throws -> Envelope {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return Envelope() }

        let attributes = try manager.attributesOfItem(atPath: fileURL.path)
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

    private func saveUnlocked(_ envelope: Envelope) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
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
