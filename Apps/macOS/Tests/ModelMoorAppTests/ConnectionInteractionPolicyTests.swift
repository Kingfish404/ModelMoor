@testable import ModelMoor
import ModelMoorApplication
import ModelMoorCore
import XCTest

final class ConnectionInteractionPolicyTests: XCTestCase {
    func testSelectedConnectionCommandsRequirePhaseAndEnabledMapping() {
        let enabled = TunnelConfiguration(name: "GPU Lab", sshHost: "gpu.example")
        let disabled = TunnelConfiguration(
            name: "Disabled",
            sshHost: "disabled.example",
            mappings: [PortMappingConfiguration(enabled: false)],
            connectOnLaunch: false
        )

        XCTAssertTrue(ConnectionInteractionPolicy.canConnect(enabled, phase: .stopped))
        XCTAssertTrue(ConnectionInteractionPolicy.canConnect(enabled, phase: .failed))
        XCTAssertFalse(ConnectionInteractionPolicy.canConnect(enabled, phase: .connecting))
        XCTAssertFalse(ConnectionInteractionPolicy.canConnect(disabled, phase: .stopped))

        for phase in [
            TunnelPhase.waitingForNetwork,
            .connecting,
            .connected,
            .waitingToRetry
        ] {
            XCTAssertTrue(ConnectionInteractionPolicy.canDisconnect(phase: phase))
            XCTAssertTrue(ConnectionInteractionPolicy.canPerformPrimaryAction(enabled, phase: phase))
        }
        for phase in [TunnelPhase.stopped, .disconnecting, .failed] {
            XCTAssertFalse(ConnectionInteractionPolicy.canDisconnect(phase: phase))
        }
        XCTAssertFalse(ConnectionInteractionPolicy.canPerformPrimaryAction(
            enabled,
            phase: .disconnecting
        ))
        XCTAssertFalse(ConnectionInteractionPolicy.canPerformPrimaryAction(
            disabled,
            phase: .failed
        ))
    }

    func testBatchCommandsUseRequestedIdentityAndPhase() {
        let tunnel = TunnelConfiguration(name: "GPU Lab", sshHost: "gpu.example")
        let stopped = [
            tunnel.id: TunnelStatus(
                tunnelID: tunnel.id,
                phase: .stopped,
                message: "Stopped"
            )
        ]

        XCTAssertTrue(ConnectionInteractionPolicy.canConnectAll(
            tunnels: [tunnel],
            statuses: stopped,
            requestedTunnelIDs: []
        ))
        XCTAssertFalse(ConnectionInteractionPolicy.canConnectAll(
            tunnels: [tunnel],
            statuses: stopped,
            requestedTunnelIDs: [tunnel.id]
        ))

        let disconnecting = [
            tunnel.id: TunnelStatus(
                tunnelID: tunnel.id,
                phase: .disconnecting,
                message: "Disconnecting"
            )
        ]
        XCTAssertFalse(ConnectionInteractionPolicy.canConnectAll(
            tunnels: [tunnel],
            statuses: disconnecting,
            requestedTunnelIDs: []
        ))

        let disabled = TunnelConfiguration(
            name: "Disabled",
            sshHost: "disabled.example",
            mappings: [PortMappingConfiguration(enabled: false)],
            connectOnLaunch: false
        )
        XCTAssertFalse(ConnectionInteractionPolicy.canConnectAll(
            tunnels: [disabled],
            statuses: [:],
            requestedTunnelIDs: []
        ))
        XCTAssertFalse(ConnectionInteractionPolicy.canDisconnectAll(requestedTunnelIDs: []))
        XCTAssertTrue(ConnectionInteractionPolicy.canDisconnectAll(
            requestedTunnelIDs: [tunnel.id]
        ))
    }

    func testTUIStyleDesiredStateAndRetryEligibilityUsesTheSharedPolicy() {
        let tunnel = TunnelConfiguration(name: "GPU Lab", sshHost: "gpu.example")

        XCTAssertTrue(ConnectionInteractionPolicy.canToggleDesiredState(
            tunnel,
            phase: .stopped,
            isRequested: false
        ))
        XCTAssertFalse(ConnectionInteractionPolicy.canToggleDesiredState(
            tunnel,
            phase: .failed,
            isRequested: false
        ))
        XCTAssertTrue(ConnectionInteractionPolicy.canToggleDesiredState(
            tunnel,
            phase: .failed,
            isRequested: true
        ))
        XCTAssertTrue(ConnectionInteractionPolicy.canRetry(tunnel, phase: .failed))
        XCTAssertFalse(ConnectionInteractionPolicy.canRetry(tunnel, phase: .connected))
    }
}
