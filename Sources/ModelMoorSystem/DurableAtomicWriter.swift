import Foundation
import ModelMoorCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Crash-safe single-file writer: creates a sibling temporary file with
/// 0600 permissions, fsyncs contents, installs via rename (or hard link when
/// `replacing` is false and the destination must not be overwritten), then
/// fsyncs the containing directory.
enum DurableAtomicWriter {
    static func writeAtomically(_ data: Data, to destination: URL, replacing: Bool) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let fileDescriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fileDescriptor >= 0 else { throw posixError("create temporary configuration file") }
        var isOpen = true
        defer {
            if isOpen { close(fileDescriptor) }
            unlink(temporary.path)
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = write(fileDescriptor, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write configuration data")
                }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
        }
        guard fsync(fileDescriptor) == 0 else { throw posixError("sync configuration data") }
        guard close(fileDescriptor) == 0 else { throw posixError("close configuration file") }
        isOpen = false

        let result: Int32
        if replacing {
            result = rename(temporary.path, destination.path)
        } else {
            result = link(temporary.path, destination.path)
            if result == 0 { unlink(temporary.path) }
        }
        guard result == 0 else {
            if !replacing, errno == EEXIST { return }
            throw posixError("install configuration file")
        }

        let directoryDescriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw posixError("open configuration directory") }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw posixError("sync configuration directory") }
    }

    private static func posixError(_ operation: String) -> ConfigurationError {
        ConfigurationError.unreadable("Could not \(operation): \(String(cString: strerror(errno)))")
    }
}
