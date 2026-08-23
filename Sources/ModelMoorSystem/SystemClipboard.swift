import Foundation

/// Cross-platform clipboard writer used by the CLI and TUI: pbcopy on macOS,
/// wl-copy / xclip / xsel on Linux. Never fails silently into stdout — the
/// caller decides whether to show the value.
public enum SystemClipboard {
    public enum ClipboardError: LocalizedError {
        case unavailable
        case writeFailed

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                "No clipboard helper is available (pbcopy, wl-copy, xclip or xsel)."
            case .writeFailed:
                "Could not copy the value to the clipboard."
            }
        }
    }

    public static func copy(_ value: String) throws {
        let helpers: [(path: String, arguments: [String])] = [
            ("/usr/bin/pbcopy", []),
            ("/usr/bin/wl-copy", []),
            ("/usr/bin/xclip", ["-selection", "clipboard"]),
            ("/usr/bin/xsel", ["--clipboard", "--input"])
        ]
        var attempted = false
        for helper in helpers where FileManager.default.isExecutableFile(atPath: helper.path) {
            attempted = true
            let process = Process()
            let input = Pipe()
            process.executableURL = URL(fileURLWithPath: helper.path)
            process.arguments = helper.arguments
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            input.fileHandleForWriting.write(Data(value.utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return }
        }
        throw attempted ? ClipboardError.writeFailed : ClipboardError.unavailable
    }
}
