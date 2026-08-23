import Foundation
import ModelMoorApplication
import ModelMoorCore
import ModelMoorSystem

struct SidebarEndpointCounts: Equatable {
    var llm = 0
    var other = 0

    static let zero = Self()
}

struct SidebarPortForward: Identifiable, Equatable {
    let connection: TunnelConfiguration
    let mapping: PortMappingConfiguration

    var id: UUID { mapping.id }
}

private struct SidebarSearchEntry<Value> {
    let value: Value
    let document: PresentationSearchDocument
}

/// Relationship topology and searchable fields prepared once for each
/// tunnel/endpoint/inspection revision. Query changes only filter these
/// entries; they do not rebuild mapping ownership, endpoint counts, or model
/// field arrays on every keystroke.
private struct SidebarSearchCorpus {
    let connectionNamesByMappingID: [UUID: String]
    let endpointCountsByTunnelID: [UUID: SidebarEndpointCounts]
    private let tunnels: [SidebarSearchEntry<TunnelConfiguration>]
    private let llmEndpoints: [SidebarSearchEntry<APIEndpointConfiguration>]
    private let otherEndpoints: [SidebarSearchEntry<APIEndpointConfiguration>]
    private let portForwards: [SidebarSearchEntry<SidebarPortForward>]

    init(
        configuration: ModelMoorConfiguration,
        inspections: [UUID: EndpointInspection]
    ) {
        var mappingOwners: [UUID: (tunnelID: UUID, connectionName: String)] = [:]
        mappingOwners.reserveCapacity(configuration.tunnels.reduce(0) { $0 + $1.mappings.count })
        for tunnel in configuration.tunnels {
            for mapping in tunnel.mappings {
                mappingOwners[mapping.id] = (tunnel.id, tunnel.name)
            }
        }
        connectionNamesByMappingID = mappingOwners.mapValues { $0.connectionName }

        let referencedMappingIDs = Set(configuration.endpoints.compactMap { endpoint -> UUID? in
            guard case let .sshMapping(mappingID, _) = endpoint.source else { return nil }
            return mappingID
        })

        var countsByTunnelID: [UUID: SidebarEndpointCounts] = [:]
        countsByTunnelID.reserveCapacity(configuration.tunnels.count)
        var preparedLLMEndpoints: [SidebarSearchEntry<APIEndpointConfiguration>] = []
        var preparedOtherEndpoints: [SidebarSearchEntry<APIEndpointConfiguration>] = []
        preparedLLMEndpoints.reserveCapacity(configuration.endpoints.count)
        preparedOtherEndpoints.reserveCapacity(configuration.endpoints.count)

        for endpoint in configuration.endpoints {
            let recognized = SidebarSearchIndex.isRecognizedLLMEndpoint(
                endpoint,
                inspections: inspections
            )
            if case let .sshMapping(mappingID, _) = endpoint.source,
               let owner = mappingOwners[mappingID] {
                var counts = countsByTunnelID[owner.tunnelID, default: .zero]
                if recognized { counts.llm += 1 } else { counts.other += 1 }
                countsByTunnelID[owner.tunnelID] = counts
            }

            let entry = SidebarSearchEntry(
                value: endpoint,
                document: PresentationSearchDocument(fields: SidebarSearchIndex.searchFields(
                    endpoint,
                    inspections: inspections,
                    connectionNamesByMappingID: connectionNamesByMappingID
                ))
            )
            if recognized {
                if case .managedCLIProxy = endpoint.source { continue }
                preparedLLMEndpoints.append(entry)
            } else {
                preparedOtherEndpoints.append(entry)
            }
        }
        endpointCountsByTunnelID = countsByTunnelID
        llmEndpoints = preparedLLMEndpoints
        otherEndpoints = preparedOtherEndpoints

        tunnels = configuration.tunnels.map { tunnel in
            SidebarSearchEntry(
                value: tunnel,
                document: PresentationSearchDocument(fields: [tunnel.name, tunnel.sshHost]
                    + tunnel.mappings.flatMap { mapping in
                        [mapping.name, mapping.listenHost, mapping.destinationHost]
                    })
            )
        }

        var preparedPortForwards: [SidebarSearchEntry<SidebarPortForward>] = []
        preparedPortForwards.reserveCapacity(mappingOwners.count)
        for tunnel in configuration.tunnels {
            for mapping in tunnel.mappings where !referencedMappingIDs.contains(mapping.id) {
                let item = SidebarPortForward(connection: tunnel, mapping: mapping)
                preparedPortForwards.append(SidebarSearchEntry(
                    value: item,
                    document: PresentationSearchDocument(fields: [
                        tunnel.name,
                        tunnel.sshHost,
                        mapping.name,
                        mapping.listenHost,
                        mapping.destinationHost
                    ])
                ))
            }
        }
        portForwards = preparedPortForwards
    }

    func index(matching query: PresentationSearchQuery) -> SidebarSearchIndex {
        SidebarSearchIndex(
            connectionNamesByMappingID: connectionNamesByMappingID,
            endpointCountsByTunnelID: endpointCountsByTunnelID,
            tunnels: tunnels.filter { query.matches(document: $0.document) }.map(\.value),
            llmEndpoints: llmEndpoints.filter { query.matches(document: $0.document) }.map(\.value),
            otherEndpoints: otherEndpoints.filter { query.matches(document: $0.document) }.map(\.value),
            portForwards: portForwards.filter { query.matches(document: $0.document) }.map(\.value)
        )
    }
}

/// Builds all sidebar relationships in linear passes. SwiftUI may reevaluate
/// the sidebar frequently while status and usage values change, so rows must
/// not rescan every endpoint to derive their subtitles.
struct SidebarSearchIndex {
    let connectionNamesByMappingID: [UUID: String]
    let endpointCountsByTunnelID: [UUID: SidebarEndpointCounts]
    let tunnels: [TunnelConfiguration]
    let llmEndpoints: [APIEndpointConfiguration]
    let otherEndpoints: [APIEndpointConfiguration]
    let portForwards: [SidebarPortForward]

    init(
        configuration: ModelMoorConfiguration,
        inspections: [UUID: EndpointInspection],
        query: PresentationSearchQuery
    ) {
        self = SidebarSearchCorpus(
            configuration: configuration,
            inspections: inspections
        ).index(matching: query)
    }

    fileprivate init(
        connectionNamesByMappingID: [UUID: String],
        endpointCountsByTunnelID: [UUID: SidebarEndpointCounts],
        tunnels: [TunnelConfiguration],
        llmEndpoints: [APIEndpointConfiguration],
        otherEndpoints: [APIEndpointConfiguration],
        portForwards: [SidebarPortForward]
    ) {
        self.connectionNamesByMappingID = connectionNamesByMappingID
        self.endpointCountsByTunnelID = endpointCountsByTunnelID
        self.tunnels = tunnels
        self.llmEndpoints = llmEndpoints
        self.otherEndpoints = otherEndpoints
        self.portForwards = portForwards
    }

    static func isRecognizedLLMEndpoint(
        _ endpoint: APIEndpointConfiguration,
        inspections: [UUID: EndpointInspection]
    ) -> Bool {
        endpoint.kind.isLLMAPI
            && inspections[endpoint.id]?.classification != .otherHTTPService
    }

    fileprivate static func searchFields(
        _ endpoint: APIEndpointConfiguration,
        inspections: [UUID: EndpointInspection],
        connectionNamesByMappingID: [UUID: String]
    ) -> [String] {
        let source: String
        switch endpoint.source {
        case let .directHTTPS(origin): source = origin.host ?? "Direct HTTPS"
        case .managedCLIProxy: source = "Subscription accounts"
        case let .sshMapping(mappingID, _):
            source = connectionNamesByMappingID[mappingID].map { "via \($0)" }
                ?? "Missing SSH connection"
        }
        return [endpoint.name, endpoint.kind.rawValue, source]
            + (inspections[endpoint.id]?.models?.map(\.id) ?? [])
    }
}

/// Stable reference cache owned by the sidebar view. Unrelated AppModel
/// publications reuse the final result; a query change reuses the prepared
/// corpus; only a relevant source revision rebuilds relationship topology.
final class SidebarSearchIndexCache {
    private var sourceRevision: UInt64?
    private var corpus: SidebarSearchCorpus?
    private var query: PresentationSearchQuery?
    private var result: SidebarSearchIndex?
    private(set) var corpusBuildCount = 0
    private(set) var resultBuildCount = 0

    func index(
        sourceRevision: UInt64,
        configuration: ModelMoorConfiguration,
        inspections: [UUID: EndpointInspection],
        query: PresentationSearchQuery
    ) -> SidebarSearchIndex {
        if self.sourceRevision != sourceRevision || corpus == nil {
            corpus = SidebarSearchCorpus(
                configuration: configuration,
                inspections: inspections
            )
            self.sourceRevision = sourceRevision
            self.query = nil
            result = nil
            corpusBuildCount += 1
        }

        if self.query == query, let result {
            return result
        }

        let result = corpus!.index(matching: query)
        self.query = query
        self.result = result
        resultBuildCount += 1
        return result
    }
}

enum SidebarSearchSelectionRecovery: Equatable {
    case clearSearch
    case clearSearchAndExpandOthers
}

enum SidebarSearchSelectionVisibility {
    static func isVisible(
        _ selection: NavigationSelection?,
        in index: SidebarSearchIndex
    ) -> Bool {
        switch selection {
        case let .connection(id):
            return index.tunnels.contains { $0.id == id }
                || index.portForwards.contains { $0.connection.id == id }
        case let .endpoint(id):
            return index.llmEndpoints.contains { $0.id == id }
                || index.otherEndpoints.contains { $0.id == id }
        case .overview, .subscriptionAccounts, .gateway, .usage, .settings, nil:
            return true
        }
    }

    static func recovery(
        _ selection: NavigationSelection?,
        configuration: ModelMoorConfiguration,
        inspections: [UUID: EndpointInspection]
    ) -> SidebarSearchSelectionRecovery? {
        switch selection {
        case let .connection(id):
            return configuration.tunnels.contains { $0.id == id } ? .clearSearch : nil
        case let .endpoint(id):
            guard let endpoint = configuration.endpoints.first(where: { $0.id == id }) else {
                return nil
            }
            let isRecognized = SidebarSearchIndex.isRecognizedLLMEndpoint(
                endpoint,
                inspections: inspections
            )
            if case .managedCLIProxy = endpoint.source, isRecognized {
                return nil
            }
            return isRecognized ? .clearSearch : .clearSearchAndExpandOthers
        case .overview, .subscriptionAccounts, .gateway, .usage, .settings, nil:
            return nil
        }
    }
}
