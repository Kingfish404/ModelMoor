@testable import ModelMoor
import ModelMoorApplication
import ModelMoorCore
import ModelMoorSystem
import XCTest

final class SidebarSearchTests: XCTestCase {
    func testSidebarSearchMatchesTermsAcrossFieldsCaseInsensitively() {
        XCTAssertTrue(PresentationSearchQuery("GPU lab").matches(
            fields: ["Training GPU", "compute.lab", "Inference"]
        ))
        XCTAssertTrue(PresentationSearchQuery("DEEPSEEK").matches(
            fields: ["deepseek-r1", "OpenAI compatible"]
        ))
        XCTAssertFalse(PresentationSearchQuery("gpu cloud").matches(
            fields: ["Training GPU", "compute.lab"]
        ))
    }

    func testSidebarSearchTreatsWhitespaceAsNoFilter() {
        XCTAssertTrue(PresentationSearchQuery("  \n ").matches(fields: []))
        XCTAssertEqual(PresentationSearchQuery("  endpoint  ").normalizedText, "endpoint")
    }

    func testPreparedSearchDocumentPreservesFieldBoundariesAndTermSemantics() {
        let document = PresentationSearchDocument(fields: [
            "Training GPU",
            "compute.lab",
            "deepseek-r1"
        ])

        XCTAssertTrue(PresentationSearchQuery("gpu deepseek").matches(document: document))
        XCTAssertTrue(PresentationSearchQuery("COMPUTE.LAB").matches(document: document))
        XCTAssertFalse(PresentationSearchQuery("gpu cloud").matches(document: document))
        XCTAssertFalse(
            PresentationSearchQuery("gpucompute").matches(document: document),
            "a term must not match across two field boundaries"
        )

        let injectedBoundary = PresentationSearchDocument(fields: ["alpha\u{1F}beta"])
        XCTAssertTrue(PresentationSearchQuery("alpha beta").matches(document: injectedBoundary))
        XCTAssertFalse(PresentationSearchQuery("alphabeta").matches(document: injectedBoundary))
    }

    func testSidebarIndexBuildsRelationshipsAndFiltersAcrossVisibleFields() {
        let usedMapping = PortMappingConfiguration(name: "Inference API")
        let spareMapping = PortMappingConfiguration(name: "Metrics")
        let tunnel = TunnelConfiguration(
            name: "GPU Lab",
            sshHost: "compute.lab",
            mappings: [usedMapping, spareMapping]
        )
        let llmEndpoint = APIEndpointConfiguration(
            name: "Primary Inference",
            source: .sshMapping(mappingID: usedMapping.id, originScheme: .http)
        )
        let otherEndpoint = APIEndpointConfiguration(
            name: "Health Dashboard",
            source: .sshMapping(mappingID: usedMapping.id, originScheme: .http),
            kind: .customHTTP,
            modelListPath: nil
        )
        let inspection = EndpointInspection(
            endpointID: llmEndpoint.id,
            url: nil,
            models: [RemoteModelMetadata(id: "deepseek-r1")],
            classification: .llmAPI
        )
        let configuration = ModelMoorConfiguration(
            tunnels: [tunnel],
            endpoints: [llmEndpoint, otherEndpoint]
        )

        let index = SidebarSearchIndex(
            configuration: configuration,
            inspections: [llmEndpoint.id: inspection],
            query: PresentationSearchQuery("gpu deepseek")
        )

        XCTAssertEqual(index.tunnels.map(\.id), [])
        XCTAssertEqual(index.llmEndpoints.map(\.id), [llmEndpoint.id])
        XCTAssertTrue(index.otherEndpoints.isEmpty)
        XCTAssertEqual(index.portForwards.map(\.id), [])
        XCTAssertEqual(
            index.endpointCountsByTunnelID[tunnel.id],
            SidebarEndpointCounts(llm: 1, other: 1)
        )

        let unfiltered = SidebarSearchIndex(
            configuration: configuration,
            inspections: [llmEndpoint.id: inspection],
            query: PresentationSearchQuery("")
        )
        XCTAssertEqual(unfiltered.tunnels.map(\.id), [tunnel.id])
        XCTAssertEqual(unfiltered.portForwards.map(\.id), [spareMapping.id])
    }

    func testSidebarIndexCacheSeparatesSourceAndQueryInvalidation() {
        let mapping = PortMappingConfiguration(name: "Inference")
        let tunnel = TunnelConfiguration(
            name: "GPU Lab",
            sshHost: "compute.lab",
            mappings: [mapping]
        )
        let endpoint = APIEndpointConfiguration(
            name: "Primary Inference",
            source: .sshMapping(mappingID: mapping.id, originScheme: .http)
        )
        let configuration = ModelMoorConfiguration(
            tunnels: [tunnel],
            endpoints: [endpoint]
        )
        let initialInspection = EndpointInspection(
            endpointID: endpoint.id,
            url: nil,
            models: [RemoteModelMetadata(id: "deepseek-r1")],
            classification: .llmAPI
        )
        let cache = SidebarSearchIndexCache()

        let first = cache.index(
            sourceRevision: 0,
            configuration: configuration,
            inspections: [endpoint.id: initialInspection],
            query: PresentationSearchQuery("deepseek")
        )
        XCTAssertEqual(first.llmEndpoints.map(\.id), [endpoint.id])
        XCTAssertEqual(cache.corpusBuildCount, 1)
        XCTAssertEqual(cache.resultBuildCount, 1)

        _ = cache.index(
            sourceRevision: 0,
            configuration: configuration,
            inspections: [endpoint.id: initialInspection],
            query: PresentationSearchQuery("deepseek")
        )
        XCTAssertEqual(cache.corpusBuildCount, 1)
        XCTAssertEqual(cache.resultBuildCount, 1, "unrelated view updates must reuse the final result")

        let hostResult = cache.index(
            sourceRevision: 0,
            configuration: configuration,
            inspections: [endpoint.id: initialInspection],
            query: PresentationSearchQuery("compute.lab")
        )
        XCTAssertEqual(hostResult.tunnels.map(\.id), [tunnel.id])
        XCTAssertEqual(cache.corpusBuildCount, 1, "query changes must reuse prepared relationships")
        XCTAssertEqual(cache.resultBuildCount, 2)

        let updatedInspection = EndpointInspection(
            endpointID: endpoint.id,
            url: nil,
            models: [RemoteModelMetadata(id: "qwen-max")],
            classification: .llmAPI
        )
        let updated = cache.index(
            sourceRevision: 1,
            configuration: configuration,
            inspections: [endpoint.id: updatedInspection],
            query: PresentationSearchQuery("qwen")
        )
        XCTAssertEqual(updated.llmEndpoints.map(\.id), [endpoint.id])
        XCTAssertEqual(cache.corpusBuildCount, 2)
        XCTAssertEqual(cache.resultBuildCount, 3)
    }

    func testSearchVisibilityOffersRecoveryOnlyForRevealableSelections() {
        let mapping = PortMappingConfiguration(name: "Inference")
        let tunnel = TunnelConfiguration(
            name: "GPU Lab",
            sshHost: "compute.lab",
            mappings: [mapping]
        )
        let endpoint = APIEndpointConfiguration(
            name: "Primary Inference",
            source: .sshMapping(mappingID: mapping.id, originScheme: .http)
        )
        let otherEndpoint = APIEndpointConfiguration(
            name: "Metrics Dashboard",
            source: .sshMapping(mappingID: mapping.id, originScheme: .http),
            kind: .customHTTP,
            modelListPath: nil
        )
        let configuration = ModelMoorConfiguration(
            tunnels: [tunnel],
            endpoints: [endpoint, otherEndpoint]
        )
        let noMatches = SidebarSearchIndex(
            configuration: configuration,
            inspections: [:],
            query: PresentationSearchQuery("no-such-item")
        )

        XCTAssertFalse(SidebarSearchSelectionVisibility.isVisible(
            .connection(tunnel.id),
            in: noMatches
        ))
        XCTAssertEqual(SidebarSearchSelectionVisibility.recovery(
            .connection(tunnel.id),
            configuration: configuration,
            inspections: [:]
        ), .clearSearch)
        XCTAssertFalse(SidebarSearchSelectionVisibility.isVisible(
            .endpoint(endpoint.id),
            in: noMatches
        ))
        XCTAssertEqual(SidebarSearchSelectionVisibility.recovery(
            .endpoint(endpoint.id),
            configuration: configuration,
            inspections: [:]
        ), .clearSearch)

        XCTAssertFalse(SidebarSearchSelectionVisibility.isVisible(
            .endpoint(otherEndpoint.id),
            in: noMatches
        ))
        XCTAssertEqual(SidebarSearchSelectionVisibility.recovery(
            .endpoint(otherEndpoint.id),
            configuration: configuration,
            inspections: [:]
        ), .clearSearchAndExpandOthers)

        for selection in [
            NavigationSelection.overview,
            .gateway,
            .subscriptionAccounts,
            .usage,
            .settings
        ] {
            XCTAssertTrue(SidebarSearchSelectionVisibility.isVisible(selection, in: noMatches))
            XCTAssertNil(SidebarSearchSelectionVisibility.recovery(
                selection,
                configuration: configuration,
                inspections: [:]
            ))
        }

        let managed = APIEndpointConfiguration.managedCLIProxy(id: UUID(), port: 18_317)
        let managedConfiguration = ModelMoorConfiguration(endpoints: [managed])
        XCTAssertNil(SidebarSearchSelectionVisibility.recovery(
            .endpoint(managed.id),
            configuration: managedConfiguration,
            inspections: [:]
        ))
        XCTAssertNil(SidebarSearchSelectionVisibility.recovery(
            .endpoint(UUID()),
            configuration: configuration,
            inspections: [:]
        ))
    }

    func testLargeSidebarIndexPerformance() {
        let count = 2_000
        let tunnels = (0..<count).map { index in
            TunnelConfiguration(
                name: "GPU Cluster \(index)",
                sshHost: "gpu-\(index).example",
                mappings: [PortMappingConfiguration(name: "Inference \(index)")]
            )
        }
        let endpoints = tunnels.enumerated().map { index, tunnel in
            APIEndpointConfiguration(
                name: "Endpoint \(index)",
                source: .sshMapping(mappingID: tunnel.mappings[0].id, originScheme: .http)
            )
        }
        let configuration = ModelMoorConfiguration(tunnels: tunnels, endpoints: endpoints)
        let query = PresentationSearchQuery("Endpoint 1999")

        measure(metrics: [XCTClockMetric()]) {
            let index = SidebarSearchIndex(
                configuration: configuration,
                inspections: [:],
                query: query
            )
            XCTAssertEqual(index.llmEndpoints.count, 1)
        }
    }

    func testPreparedSidebarQueryPerformance() {
        let count = 2_000
        let tunnels = (0..<count).map { index in
            TunnelConfiguration(
                name: "GPU Cluster \(index)",
                sshHost: "gpu-\(index).example",
                mappings: [PortMappingConfiguration(name: "Inference \(index)")]
            )
        }
        let endpoints = tunnels.enumerated().map { index, tunnel in
            APIEndpointConfiguration(
                name: "Endpoint \(index)",
                source: .sshMapping(mappingID: tunnel.mappings[0].id, originScheme: .http)
            )
        }
        let configuration = ModelMoorConfiguration(tunnels: tunnels, endpoints: endpoints)
        let cache = SidebarSearchIndexCache()
        _ = cache.index(
            sourceRevision: 0,
            configuration: configuration,
            inspections: [:],
            query: PresentationSearchQuery("")
        )
        var iteration = 0

        measure(metrics: [XCTClockMetric()]) {
            let target = 1_995 + iteration % 5
            let index = cache.index(
                sourceRevision: 0,
                configuration: configuration,
                inspections: [:],
                query: PresentationSearchQuery("Endpoint \(target)")
            )
            XCTAssertEqual(index.llmEndpoints.count, 1)
            iteration += 1
        }
        XCTAssertEqual(cache.corpusBuildCount, 1)
    }
}
