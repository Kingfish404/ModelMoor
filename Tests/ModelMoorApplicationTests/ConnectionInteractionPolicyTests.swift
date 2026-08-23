import ModelMoorApplication
import ModelMoorCore
import XCTest

final class ConnectionInteractionPolicyTests: XCTestCase {
    func testSelectedAndBatchConnectionEligibilityIsPresentationIndependent() {
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

        XCTAssertTrue(ConnectionInteractionPolicy.canDisconnect(phase: .connected))
        XCTAssertTrue(ConnectionInteractionPolicy.canDisconnect(phase: .waitingToRetry))
        XCTAssertFalse(ConnectionInteractionPolicy.canDisconnect(phase: .failed))
        XCTAssertFalse(ConnectionInteractionPolicy.canDisconnect(phase: .disconnecting))

        XCTAssertTrue(ConnectionInteractionPolicy.canToggleDesiredState(
            enabled,
            phase: .failed,
            isRequested: true
        ))
        XCTAssertFalse(ConnectionInteractionPolicy.canToggleDesiredState(
            enabled,
            phase: .failed,
            isRequested: false
        ))
        XCTAssertTrue(ConnectionInteractionPolicy.canRetry(enabled, phase: .failed))
        XCTAssertFalse(ConnectionInteractionPolicy.canRetry(disabled, phase: .failed))

        XCTAssertTrue(ConnectionInteractionPolicy.canConnectAll(
            tunnels: [enabled],
            statuses: [:],
            requestedTunnelIDs: []
        ))
        XCTAssertFalse(ConnectionInteractionPolicy.canConnectAll(
            tunnels: [enabled],
            statuses: [:],
            requestedTunnelIDs: [enabled.id]
        ))
        XCTAssertTrue(ConnectionInteractionPolicy.canDisconnectAll(
            requestedTunnelIDs: [enabled.id]
        ))
    }
}
