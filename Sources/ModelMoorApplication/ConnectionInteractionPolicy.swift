import Foundation
import ModelMoorCore

/// Presentation-independent eligibility for SSH connection commands.
///
/// GUI menus, toolbars and the TUI must expose the same valid operations for
/// a tunnel phase. Keeping the rules above both presentation packages also
/// gives command handlers a final guard against stale or duplicated input.
public enum ConnectionInteractionPolicy {
    public static func canConnect(
        _ tunnel: TunnelConfiguration,
        phase: TunnelPhase
    ) -> Bool {
        (phase == .stopped || phase == .failed) && !tunnel.enabledMappings.isEmpty
    }

    public static func canDisconnect(phase: TunnelPhase) -> Bool {
        switch phase {
        case .waitingForNetwork, .connecting, .connected, .waitingToRetry:
            true
        case .stopped, .disconnecting, .failed:
            false
        }
    }

    public static func canPerformPrimaryAction(
        _ tunnel: TunnelConfiguration,
        phase: TunnelPhase
    ) -> Bool {
        usesDisconnectAction(phase: phase)
            ? canDisconnect(phase: phase)
            : canConnect(tunnel, phase: phase)
    }

    /// The TUI exposes disconnect and retry as separate shortcuts. Desired
    /// runtime identity therefore matters in addition to display phase: a
    /// requested failed tunnel may still be removed from the desired set,
    /// while an unrequested failure is recovered through the retry command.
    public static func canToggleDesiredState(
        _ tunnel: TunnelConfiguration,
        phase: TunnelPhase,
        isRequested: Bool
    ) -> Bool {
        if isRequested { return phase != .disconnecting }
        return phase == .stopped && !tunnel.enabledMappings.isEmpty
    }

    public static func canRetry(
        _ tunnel: TunnelConfiguration,
        phase: TunnelPhase
    ) -> Bool {
        phase == .failed && !tunnel.enabledMappings.isEmpty
    }

    public static func canConnectAll(
        tunnels: [TunnelConfiguration],
        statuses: [UUID: TunnelStatus],
        requestedTunnelIDs: Set<UUID>
    ) -> Bool {
        tunnels.contains { tunnel in
            !requestedTunnelIDs.contains(tunnel.id)
                && canConnect(tunnel, phase: statuses[tunnel.id]?.phase ?? .stopped)
        }
    }

    public static func canDisconnectAll(requestedTunnelIDs: Set<UUID>) -> Bool {
        !requestedTunnelIDs.isEmpty
    }

    private static func usesDisconnectAction(phase: TunnelPhase) -> Bool {
        switch phase {
        case .waitingForNetwork, .connecting, .connected, .waitingToRetry:
            true
        case .stopped, .disconnecting, .failed:
            false
        }
    }
}
