@testable import ModelMoor
import ModelMoorApplication
import ModelMoorCore
import ModelMoorSystem
import XCTest

final class EndpointInteractionPolicyTests: XCTestCase {
    func testOnlyUserOwnedDirectHTTPSEndpointsCanBeDuplicated() {
        let direct = APIEndpointConfiguration(
            name: "Direct",
            source: .directHTTPS(originURL: URL(string: "https://api.example.com")!)
        )
        let ssh = APIEndpointConfiguration(
            name: "SSH",
            source: .sshMapping(mappingID: UUID(), originScheme: .http)
        )
        let managed = APIEndpointConfiguration.managedCLIProxy(id: UUID(), port: 18_317)

        XCTAssertTrue(EndpointInteractionPolicy.canDuplicate(direct))
        XCTAssertFalse(EndpointInteractionPolicy.canDuplicate(ssh))
        XCTAssertFalse(EndpointInteractionPolicy.canDuplicate(managed))
    }

    func testEndpointCommandsRequireAResolvableURLOrRefreshableEndpoint() {
        var endpoint = APIEndpointConfiguration(
            name: "Direct",
            source: .directHTTPS(originURL: URL(string: "https://api.example.com")!)
        )

        XCTAssertFalse(EndpointInteractionPolicy.canCopyURL(nil))
        XCTAssertTrue(EndpointInteractionPolicy.canCopyURL(URL(string: "https://api.example.com/v1")))
        XCTAssertTrue(EndpointInteractionPolicy.canRefresh(
            endpoint,
            inspectingEndpointIDs: []
        ))
        XCTAssertFalse(EndpointInteractionPolicy.canRefresh(
            endpoint,
            inspectingEndpointIDs: [endpoint.id]
        ))

        endpoint.enabled = false
        XCTAssertFalse(EndpointInteractionPolicy.canRefresh(
            endpoint,
            inspectingEndpointIDs: []
        ))
    }

    func testRefreshAllAvailabilityMatchesEveryCommandSurface() {
        var endpoint = APIEndpointConfiguration(
            name: "Direct",
            source: .directHTTPS(originURL: URL(string: "https://api.example.com")!)
        )

        XCTAssertFalse(EndpointInteractionPolicy.canRefreshAll(
            endpoints: [],
            inspectingEndpointIDs: []
        ))
        XCTAssertTrue(EndpointInteractionPolicy.canRefreshAll(
            endpoints: [endpoint],
            inspectingEndpointIDs: []
        ))
        XCTAssertFalse(EndpointInteractionPolicy.canRefreshAll(
            endpoints: [endpoint],
            inspectingEndpointIDs: [endpoint.id]
        ))
        endpoint.enabled = false
        XCTAssertFalse(EndpointInteractionPolicy.canRefreshAll(
            endpoints: [endpoint],
            inspectingEndpointIDs: []
        ))
    }

    func testUsageRefreshRequiresAnActiveVisibleNonMiniaturizedWindow() {
        XCTAssertTrue(PresentationRefreshPolicy.shouldRefreshUsage(
            windowIsVisible: true,
            windowIsMiniaturized: false,
            applicationIsActive: true
        ))
        XCTAssertFalse(PresentationRefreshPolicy.shouldRefreshUsage(
            windowIsVisible: false,
            windowIsMiniaturized: false,
            applicationIsActive: true
        ))
        XCTAssertFalse(PresentationRefreshPolicy.shouldRefreshUsage(
            windowIsVisible: true,
            windowIsMiniaturized: true,
            applicationIsActive: true
        ))
        XCTAssertFalse(PresentationRefreshPolicy.shouldRefreshUsage(
            windowIsVisible: true,
            windowIsMiniaturized: false,
            applicationIsActive: false
        ))
    }

    func testSubscriptionControlsRespectGUIRuntimeOwnership() {
        var availability = ManagedSubscriptionInteractionPolicy.availability(
            runtimeState: .ownedExternally(owner: "modelmoor-tui"),
            cliProxyState: .running(port: 18_317),
            hasActiveLogin: false
        )
        XCTAssertFalse(availability.canStartLogin)
        XCTAssertFalse(availability.canRefreshAccounts)
        XCTAssertFalse(availability.canMutateAccounts)

        availability = ManagedSubscriptionInteractionPolicy.availability(
            runtimeState: .running,
            cliProxyState: .running(port: 18_317),
            hasActiveLogin: false
        )
        XCTAssertTrue(availability.canStartLogin)
        XCTAssertTrue(availability.canRefreshAccounts)
        XCTAssertTrue(availability.canMutateAccounts)
    }
}
