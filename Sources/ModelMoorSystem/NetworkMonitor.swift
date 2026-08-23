import Foundation
#if canImport(Network)
import Network
#endif

public enum NetworkAvailability: String, Equatable, Sendable {
    case available
    case unavailable
}

/// Reports coarse network availability to the tunnel supervision layer.
///
/// On macOS this wraps `NWPathMonitor`. On Linux there is no equivalent
/// system framework in the dependency-free baseline, so the monitor reports
/// `.available` once and lets the SSH supervision loop detect and recover
/// from failures through its existing retry/backoff path.
public final class NetworkMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable (NetworkAvailability) -> Void

    private let queue: DispatchQueue
    private let handler: Handler
    private let lock = NSLock()
    private var started = false
    #if canImport(Network)
    private let monitor = NWPathMonitor()
    #endif

    public init(
        queue: DispatchQueue = DispatchQueue(label: "com.modelmoor.network-monitor", qos: .utility),
        handler: @escaping Handler
    ) {
        self.queue = queue
        self.handler = handler
    }

    public func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        #if canImport(Network)
        monitor.pathUpdateHandler = { [handler] path in
            handler(path.status == .satisfied ? .available : .unavailable)
        }
        monitor.start(queue: queue)
        #else
        queue.async { [handler] in handler(.available) }
        #endif
    }

    public func cancel() {
        let shouldCancel = lock.withLock { () -> Bool in
            guard started else { return false }
            started = false
            return true
        }
        guard shouldCancel else { return }
        #if canImport(Network)
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        #endif
    }
}
