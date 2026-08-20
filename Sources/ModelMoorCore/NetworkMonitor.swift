import Foundation
import Network

public enum NetworkAvailability: String, Equatable, Sendable {
    case available
    case unavailable
}

public final class NetworkMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable (NetworkAvailability) -> Void

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let handler: Handler
    private let lock = NSLock()
    private var started = false

    public init(
        queue: DispatchQueue = DispatchQueue(label: "com.modelmoor.network-monitor", qos: .utility),
        handler: @escaping Handler
    ) {
        self.monitor = NWPathMonitor()
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
        monitor.pathUpdateHandler = { [handler] path in
            handler(path.status == .satisfied ? .available : .unavailable)
        }
        monitor.start(queue: queue)
    }

    public func cancel() {
        let shouldCancel = lock.withLock { () -> Bool in
            guard started else { return false }
            started = false
            return true
        }
        guard shouldCancel else { return }
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }
}
