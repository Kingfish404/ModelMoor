import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Cross-platform SIGINT/SIGTERM suspension used by long-running presentation
/// processes. POSIX constants and signal installation stay in System so the
/// CLI and future frontends do not grow platform shims of their own.
public enum ProcessTerminationSignal {
    /// Routes SIGINT/SIGTERM through dispatch-compatible no-op handlers while
    /// preserving the default disposition for subsequently exec'd children.
    public static func prepareDispatchSources() {
        signal(SIGINT, dispatchSignalHandler)
        signal(SIGTERM, dispatchSignalHandler)
    }

    /// Installs both signal sources before publishing readiness. Callers that
    /// expose a ready marker must do so through `onReady`; otherwise a signal
    /// can arrive between the marker and source installation and be lost.
    public static func wait(onReady: @escaping @Sendable () -> Void = {}) async {
        // A caught disposition resets to SIG_DFL in exec'd children; SIG_IGN
        // does not. Keeping a no-op handler here lets DispatchSource own the
        // parent signal without making later SSH watchdogs ignore termination.
        prepareDispatchSources()
        await withCheckedContinuation { continuation in
            let latch = SignalLatch(continuation, onReady: onReady)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT)
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM)
            interrupt.setEventHandler { latch.resume() }
            terminate.setEventHandler { latch.resume() }
            interrupt.setRegistrationHandler { latch.didRegisterSource() }
            terminate.setRegistrationHandler { latch.didRegisterSource() }
            latch.sources = [interrupt, terminate]
            interrupt.resume()
            terminate.resume()
        }
    }
}

private func dispatchSignalHandler(_: Int32) {}

private final class SignalLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private let onReady: @Sendable () -> Void
    private var registeredSourceCount = 0
    private var readinessPublished = false
    var sources: [DispatchSourceSignal] = []

    init(
        _ continuation: CheckedContinuation<Void, Never>,
        onReady: @escaping @Sendable () -> Void
    ) {
        self.continuation = continuation
        self.onReady = onReady
    }

    func didRegisterSource() {
        let publishReadiness = lock.withLock { () -> Bool in
            guard continuation != nil, !readinessPublished else { return false }
            registeredSourceCount += 1
            guard registeredSourceCount == sources.count else { return false }
            readinessPublished = true
            return true
        }
        if publishReadiness { onReady() }
    }

    func resume() {
        lock.withLock {
            guard let continuation else { return }
            self.continuation = nil
            sources.forEach { $0.cancel() }
            sources.removeAll()
            continuation.resume()
        }
    }
}
