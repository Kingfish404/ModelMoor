import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Platform path conventions. macOS keeps the historical Library layout for
/// application data; Linux follows the XDG Base Directory specification.
/// Configuration lives under XDG-style `~/.config/modelmoor` on both
/// platforms (see `ModelMoorRuntimeProfile.configurationHome`).
public enum PlatformPaths {
    /// Whether the platform can register GUI login items (macOS only).
    public static var supportsLaunchAtLogin: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// Whether a pre-XDG legacy data-layout configuration may exist on this
    /// platform (macOS only; Linux has no legacy layout to import).
    public static var hasLegacyConfigurationLayout: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// `$XDG_CONFIG_HOME` or `~/.config`.
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let rawValue = environment["XDG_CONFIG_HOME"], !rawValue.isEmpty {
            let expanded = NSString(string: rawValue).expandingTildeInPath
            if NSString(string: expanded).isAbsolutePath {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return homeDirectory.appendingPathComponent(".config", isDirectory: true)
    }

    /// `$XDG_DATA_HOME` or `~/.local/share` on Linux; `~/Library/Application Support`
    /// on macOS.
    public static func dataHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        #if os(macOS)
        return homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        #else
        if let rawValue = environment["XDG_DATA_HOME"], !rawValue.isEmpty {
            let expanded = NSString(string: rawValue).expandingTildeInPath
            if NSString(string: expanded).isAbsolutePath {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return homeDirectory.appendingPathComponent(".local/share", isDirectory: true)
        #endif
    }

    /// Per-user runtime directory for lock files and SSH control sockets:
    /// `$XDG_RUNTIME_DIR/<identifier>` when available, else `/tmp/<identifier>-<uid>`.
    /// `identifier` is `modelmoor` for production and `modelmoor-dev` for development,
    /// preserving the historical `/tmp/modelmoor-<uid>` layout.
    public static func runtimeDirectory(
        identifier: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userID: uid_t = getuid()
    ) -> URL {
        #if os(Linux)
        if let rawValue = environment["XDG_RUNTIME_DIR"], !rawValue.isEmpty {
            let expanded = NSString(string: rawValue).expandingTildeInPath
            if NSString(string: expanded).isAbsolutePath {
                return URL(fileURLWithPath: expanded, isDirectory: true)
                    .appendingPathComponent(identifier, isDirectory: true)
            }
        }
        #endif
        return URL(fileURLWithPath: "/tmp/\(identifier)-\(userID)", isDirectory: true)
    }
}
