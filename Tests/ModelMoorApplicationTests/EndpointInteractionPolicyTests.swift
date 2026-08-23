import ModelMoorApplication
import ModelMoorCore
import XCTest

final class EndpointInteractionPolicyTests: XCTestCase {
    func testEndpointEligibilityIsPresentationIndependent() throws {
        var direct = APIEndpointConfiguration(
            name: "Direct",
            source: .directHTTPS(originURL: URL(string: "https://api.example.com")!)
        )
        let mapping = PortMappingConfiguration(name: "Inference")
        let ssh = APIEndpointConfiguration(
            name: "SSH",
            source: .sshMapping(mappingID: mapping.id, originScheme: .http)
        )
        let managed = APIEndpointConfiguration.managedCLIProxy(id: UUID(), port: 18_317)

        XCTAssertTrue(EndpointInteractionPolicy.canDuplicate(direct))
        XCTAssertFalse(EndpointInteractionPolicy.canDuplicate(ssh))
        XCTAssertFalse(EndpointInteractionPolicy.canDuplicate(managed))

        let directURL = try EndpointURLResolver.resolve(direct, mappings: [:])
        XCTAssertTrue(EndpointInteractionPolicy.canCopyURL(directURL))
        XCTAssertFalse(EndpointInteractionPolicy.canCopyURL(nil))
        XCTAssertFalse(EndpointInteractionPolicy.canCopyURL(
            try? EndpointURLResolver.resolve(ssh, mappings: [:])
        ))
        XCTAssertTrue(EndpointInteractionPolicy.canCopyURL(
            try? EndpointURLResolver.resolve(ssh, mappings: [mapping.id: mapping])
        ))

        XCTAssertTrue(EndpointInteractionPolicy.canRefresh(
            direct,
            inspectingEndpointIDs: []
        ))
        XCTAssertFalse(EndpointInteractionPolicy.canRefresh(
            direct,
            inspectingEndpointIDs: [direct.id]
        ))
        direct.enabled = false
        XCTAssertFalse(EndpointInteractionPolicy.canRefresh(
            direct,
            inspectingEndpointIDs: []
        ))

        let publicEndpoint = APIEndpointConfiguration(
            name: "Public",
            source: .directHTTPS(originURL: URL(string: "https://public.example.com")!),
            authentication: .none
        )
        let protectedEndpoint = APIEndpointConfiguration(
            name: "Protected",
            source: .directHTTPS(originURL: URL(string: "https://protected.example.com")!),
            authentication: .bearer
        )
        XCTAssertTrue(EndpointInteractionPolicy.hasRequiredCredential(
            publicEndpoint,
            availableAPIKeyIDs: []
        ))
        XCTAssertFalse(EndpointInteractionPolicy.hasRequiredCredential(
            protectedEndpoint,
            availableAPIKeyIDs: []
        ))
        XCTAssertTrue(EndpointInteractionPolicy.hasRequiredCredential(
            protectedEndpoint,
            availableAPIKeyIDs: [try XCTUnwrap(protectedEndpoint.activeAPIKeyID)]
        ))
    }
}
