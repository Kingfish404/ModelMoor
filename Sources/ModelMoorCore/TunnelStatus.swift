import Foundation

public enum TunnelPhase: String, Codable, Sendable {
    case stopped
    case waitingForNetwork
    case connecting
    case connected
    case disconnecting
    case waitingToRetry
    case failed
}

public enum TunnelFailureCategory: String, Codable, Equatable, Sendable {
    case dns
    case sshAuthentication
    case hostKey
    case localPortInUse
    case remoteForwardConflict
    case sshConfiguration
    case processExited
    case unknown

    public var requiresUserAction: Bool {
        switch self {
        case .sshAuthentication, .hostKey, .localPortInUse, .remoteForwardConflict, .sshConfiguration:
            true
        case .dns, .processExited, .unknown:
            false
        }
    }
}

public struct TunnelStatus: Equatable, Sendable {
    public var tunnelID: UUID
    public var phase: TunnelPhase
    public var message: String
    public var retryAttempt: Int
    public var changedAt: Date
    public var failureCategory: TunnelFailureCategory?

    public init(
        tunnelID: UUID,
        phase: TunnelPhase,
        message: String,
        retryAttempt: Int = 0,
        changedAt: Date = Date(),
        failureCategory: TunnelFailureCategory? = nil
    ) {
        self.tunnelID = tunnelID
        self.phase = phase
        self.message = message
        self.retryAttempt = retryAttempt
        self.changedAt = changedAt
        self.failureCategory = failureCategory
    }
}

public struct ReconnectPolicy: Equatable, Sendable {
    public var initialDelay: Duration
    public var maximumDelay: Duration

    public init(initialDelay: Duration = .seconds(1), maximumDelay: Duration = .seconds(30)) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
    }

    public func delay(afterAttempt attempt: Int) -> Duration {
        let exponent = min(max(attempt - 1, 0), 10)
        let initial = max(initialDelay.components.seconds, 1)
        let maximum = max(maximumDelay.components.seconds, initial)
        let seconds = min(initial * Int64(1 << exponent), maximum)
        return .seconds(seconds)
    }

    public func jitteredDelay(afterAttempt attempt: Int, randomUnit: Double = Double.random(in: 0...1)) -> Duration {
        let seconds = delay(afterAttempt: attempt).components.seconds
        let clampedUnit = min(max(randomUnit, 0), 1)
        let factor = 0.8 + (0.4 * clampedUnit)
        return .milliseconds(Int64((Double(seconds) * factor * 1_000).rounded()))
    }
}
