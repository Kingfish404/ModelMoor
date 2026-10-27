@testable import ModelMoor
import ModelMoorApplication
import ModelMoorCore
import ModelMoorSystem
import XCTest

final class EndpointInteractionPolicyTests: XCTestCase {
    func testClientRequestUsesResponsesOnlyForNativeCodexRoutes() {
        XCTAssertTrue(ClientConnectionSnippet.usesResponses(source: .modelMoorSubscription, upstreamModel: "codex/gpt-5"))
        XCTAssertTrue(ClientConnectionSnippet.usesResponses(source: .modelMoorSubscription, upstreamModel: "gpt-5"))
        XCTAssertFalse(ClientConnectionSnippet.usesResponses(source: .modelMoorSubscription, upstreamModel: "claude/sonnet"))
        XCTAssertFalse(ClientConnectionSnippet.usesResponses(source: .directHTTPS(originURL: URL(string: "https://api.openai.com")!), upstreamModel: "gpt-5"))
        let request = ClientConnectionSnippet.request(port: 17777, model: "my-codex", requiresAPIKey: true, usesResponses: true)
        XCTAssertTrue(request.contains("/v1/responses"))
        XCTAssertTrue(request.contains("\"input\":"))
        XCTAssertTrue(request.contains("\"store\":false"))
        XCTAssertFalse(request.contains("\"messages\":"))
    }

    func testReadinessDoesNotCountDisabledMissingOrFailedChecksAsReady() {
        let success = EndpointInspection(endpointID: UUID(), url: nil, statusCode: 200, models: [.init(id: "model")])
        XCTAssertEqual(EndpointReadiness.resolve(enabled: true, checking: false, hasCredential: true, inspection: success), .ready(1))
        XCTAssertEqual(EndpointReadiness.resolve(enabled: false, checking: false, hasCredential: true, inspection: success), .disabled)
        XCTAssertEqual(EndpointReadiness.resolve(enabled: true, checking: true, hasCredential: true, inspection: success), .checking)
        XCTAssertEqual(EndpointReadiness.resolve(enabled: true, checking: false, hasCredential: true, inspection: .init(endpointID: UUID(), url: nil)), .unknown)
        XCTAssertEqual(EndpointReadiness.resolve(enabled: true, checking: false, hasCredential: true, inspection: .init(endpointID: UUID(), url: nil, statusCode: 401)), .needsAttention("HTTP 401"))
        if case .needsAttention = EndpointReadiness.resolve(enabled: true, checking: false, hasCredential: false, inspection: success) {} else {
            XCTFail("Missing credentials must override stale successful inspections")
        }
    }

    func testClientRequestQuotesUntrustedModelNamesAndRequiresExplicitCredentials() throws {
        let modelName = "team's/\"model\";$(touch /tmp/unsafe)"
        let request = ClientConnectionSnippet.request(port: 18888, model: modelName, requiresAPIKey: true)
        XCTAssertTrue(request.contains("http://127.0.0.1:18888/v1/chat/completions"))
        XCTAssertTrue(request.contains("${OPENAI_API_KEY:?Set OPENAI_API_KEY first}"))
        let encodedBody = try XCTUnwrap(request.components(separatedBy: "--data-raw ").last)
        XCTAssertTrue(encodedBody.hasPrefix("'"))
        XCTAssertTrue(encodedBody.hasSuffix("'"))
        XCTAssertTrue(encodedBody.contains("'\"'\"'"))
        let json = String(encodedBody.dropFirst().dropLast()).replacingOccurrences(of: "'\"'\"'", with: "'")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, modelName)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertFalse(ClientConnectionSnippet.request(port: 17777, model: "local", requiresAPIKey: false).contains("Authorization"))
        XCTAssertEqual(ClientConnectionSnippet.environment(port: 18888), "export OPENAI_BASE_URL='http://127.0.0.1:18888/v1'")
    }

    func testProviderDefaultsResolveWithoutLosingAPIBasePaths() throws {
        for preset in EndpointPreset.allCases where preset != .custom {
            let parsed = try EndpointURLResolver.parseDirectBaseURL(preset.defaultBaseURL)
            XCTAssertNotNil(parsed.origin.host)
            if preset == .openRouter { XCTAssertEqual(parsed.basePath, "/api/v1") }
            if preset == .lmStudio {
                XCTAssertEqual(parsed.origin.port, 1234)
                XCTAssertEqual(parsed.basePath, "/v1")
            }
        }
        XCTAssertFalse(EndpointPreset.ollama.usesBearerAuthentication)
        XCTAssertTrue(EndpointPreset.openRouter.usesBearerAuthentication)
    }

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
            hasActiveLogin: false,
            hasAccounts: true
        )
        XCTAssertFalse(availability.canStartLogin)
        XCTAssertFalse(availability.canRefreshAccounts)
        XCTAssertFalse(availability.canMutateAccounts)

        availability = ManagedSubscriptionInteractionPolicy.availability(
            runtimeState: .running,
            hasActiveLogin: false,
            hasAccounts: true
        )
        XCTAssertTrue(availability.canStartLogin)
        XCTAssertTrue(availability.canRefreshAccounts)
        XCTAssertTrue(availability.canMutateAccounts)
    }
}
