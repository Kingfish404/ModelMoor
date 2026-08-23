import ModelMoorCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum EndpointInspectionClassification: Equatable, Sendable {
    case unknown
    case llmAPI
    case otherHTTPService
}

public struct RemoteModelMetadata: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var object: String?
    public var created: Int?
    public var ownedBy: String?

    public init(id: String, object: String? = nil, created: Int? = nil, ownedBy: String? = nil) {
        self.id = id
        self.object = object
        self.created = created
        self.ownedBy = ownedBy
    }

    private enum CodingKeys: String, CodingKey {
        case id, object, created
        case ownedBy = "owned_by"
    }
}

public struct EndpointInspection: Equatable, Sendable {
    public var endpointID: UUID
    public var url: URL?
    public var checkedAt: Date
    public var statusCode: Int?
    public var latencyMilliseconds: Int?
    public var server: String?
    public var contentType: String?
    public var models: [RemoteModelMetadata]?
    public var errorMessage: String?
    public var classification: EndpointInspectionClassification

    public init(
        endpointID: UUID,
        url: URL?,
        checkedAt: Date = Date(),
        statusCode: Int? = nil,
        latencyMilliseconds: Int? = nil,
        server: String? = nil,
        contentType: String? = nil,
        models: [RemoteModelMetadata]? = nil,
        errorMessage: String? = nil,
        classification: EndpointInspectionClassification = .unknown
    ) {
        self.endpointID = endpointID
        self.url = url
        self.checkedAt = checkedAt
        self.statusCode = statusCode
        self.latencyMilliseconds = latencyMilliseconds
        self.server = server
        self.contentType = contentType
        self.models = models
        self.errorMessage = errorMessage
        self.classification = classification
    }

    public var isReachable: Bool {
        guard let statusCode else { return false }
        return (200...499).contains(statusCode)
    }

    public var isOpenAICompatible: Bool { models != nil }

    public var mappingID: UUID { endpointID }
}

public protocol APIInspecting: Sendable {
    func inspect(
        _ endpoint: APIEndpointConfiguration,
        mappings: [UUID: PortMappingConfiguration],
        secret: String?
    ) async -> EndpointInspection
}

public struct APIInspector: APIInspecting, Sendable {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 3) {
        self.timeout = timeout
    }

    public func inspect(
        _ endpoint: APIEndpointConfiguration,
        mappings: [UUID: PortMappingConfiguration],
        secret: String? = nil
    ) async -> EndpointInspection {
        let path = endpoint.modelListPath ?? endpoint.healthPath
        let url: URL
        do {
            url = try EndpointURLResolver.resolve(endpoint, path: path, mappings: mappings)
        } catch {
            return EndpointInspection(endpointID: endpoint.id, url: nil, errorMessage: error.localizedDescription)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let secret, !secret.isEmpty {
            switch endpoint.authentication {
            case .none: break
            case .bearer: request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            case let .header(name): request.setValue(secret, forHTTPHeaderField: name)
            }
        }

        let startedAt = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let latency = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            guard let response = response as? HTTPURLResponse else {
                return EndpointInspection(
                    endpointID: endpoint.id,
                    url: url,
                    latencyMilliseconds: latency,
                    errorMessage: "The endpoint returned an invalid response"
                )
            }

            var models: [RemoteModelMetadata]?
            var errorMessage: String?
            var classification: EndpointInspectionClassification = .unknown
            if response.statusCode == 401 || response.statusCode == 403 {
                errorMessage = "Authentication required"
            } else if endpoint.modelListPath != nil, (200...299).contains(response.statusCode) {
                do {
                    switch endpoint.kind {
                    case .openAICompatible:
                        models = try Self.decodeModels(from: data)
                    case .ollama:
                        models = try Self.decodeOllamaModels(from: data)
                    case .customHTTP:
                        break
                    }
                    models?.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
                    classification = models == nil ? .otherHTTPService : .llmAPI
                } catch {
                    errorMessage = "The endpoint is reachable, but its model list is incompatible"
                    classification = .otherHTTPService
                }
            } else if endpoint.kind == .customHTTP, (200...499).contains(response.statusCode) {
                classification = .otherHTTPService
            } else if !(200...499).contains(response.statusCode) {
                errorMessage = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            }

            return EndpointInspection(
                endpointID: endpoint.id,
                url: url,
                statusCode: response.statusCode,
                latencyMilliseconds: latency,
                server: response.value(forHTTPHeaderField: "Server"),
                contentType: response.value(forHTTPHeaderField: "Content-Type"),
                models: models,
                errorMessage: errorMessage,
                classification: classification
            )
        } catch {
            return EndpointInspection(
                endpointID: endpoint.id,
                url: url,
                latencyMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
                errorMessage: error.localizedDescription
            )
        }
    }

    static func decodeModels(from data: Data) throws -> [RemoteModelMetadata] {
        try JSONDecoder().decode(ModelListEnvelope.self, from: data).data
    }

    static func decodeOllamaModels(from data: Data) throws -> [RemoteModelMetadata] {
        try JSONDecoder().decode(OllamaModelListEnvelope.self, from: data).models.map {
            RemoteModelMetadata(id: $0.name, object: "model", ownedBy: "ollama")
        }
    }

    private struct ModelListEnvelope: Decodable {
        let data: [RemoteModelMetadata]
    }

    private struct OllamaModelListEnvelope: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }
}
