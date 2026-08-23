import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import TermKit
import TUIWidgets
import ModelMoorApplication
import ModelMoorCore
import ModelMoorSystem

/// Shared launcher for the interactive terminal console. The root CLI and the
/// standalone `modelmoor-tui` executable both use this entry point so their
/// behavior cannot drift apart.
public enum ModelMoorTUIEntryPoint {
    public static func run() {
        let isTTY = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        if isTTY {
            runInteractive()
        } else {
            let status = runTextSnapshot()
            if status != 0 { Foundation.exit(status) }
        }
    }

    /// Non-TTY mode renders a stable plain-text snapshot for scripts and CI.
    /// It never acquires the runtime owner lock.
    private static func runTextSnapshot() -> Int32 {
        let done = DispatchSemaphore(value: 0)
        let result = NonTTYResult()
        Task {
            defer { done.signal() }
            do {
                let session = try ModelMoorSession(profile: .current)
                try await session.load()
                await session.refreshRuntimeState()
                let snapshot = await session.snapshot
                let owner = session.recordedRuntimeOwner()
                print(TUISnapshotRenderer.render(snapshot: snapshot, recordedOwner: owner))
            } catch {
                FileHandle.standardError.write(Data("modelmoor-tui: \(error.localizedDescription)\n".utf8))
                result.fail()
            }
        }
        done.wait()
        return result.status
    }

    private static func runInteractive() {
        let session: ModelMoorSession
        do {
            session = try ModelMoorSession(profile: .current)
        } catch {
            FileHandle.standardError.write(Data("modelmoor-tui: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }

        let app = TUIApp(session: session, glyphs: .preferred())

        // Ctrl-C arrives as a key event in raw mode; SIGTERM/SIGINT arrive as
        // real signals. Keep the dispatch sources alive for the main loop.
        ProcessTerminationSignal.prepareDispatchSources()
        for sig in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { app.requestQuit() }
            source.resume()
            signalSources.append(source)
        }

        app.setup()
        Task { await app.start() }
        Application.run()
    }

    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []
}

private final class NonTTYResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: Int32 = 0

    var status: Int32 { lock.withLock { storedStatus } }

    func fail() {
        lock.withLock { storedStatus = 1 }
    }
}
