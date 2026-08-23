import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ModelMoorCore

public struct GatewayRequest: Sendable {
    public var method: String
    public var uri: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, uri: String, headers: [String: String], body: Data) {
        self.method = method
        self.uri = uri
        self.headers = headers
        self.body = body
    }
}

public struct GatewayPreparedRequest: Sendable {
    public var routeID: UUID
    public var endpointID: UUID
    public var urlRequest: URLRequest

    public init(routeID: UUID, endpointID: UUID, urlRequest: URLRequest) {
        self.routeID = routeID
        self.endpointID = endpointID
        self.urlRequest = urlRequest
    }
}

public struct GatewayLocalResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = ["Content-Type": "application/json"], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public enum GatewayRouteDecision: Sendable {
    case local(GatewayLocalResponse)
    case upstream(GatewayPreparedRequest)
}

public struct GatewaySnapshot: Equatable, Sendable {
    public var configuration: ModelMoorConfiguration
    public var gatewayAPIKeys: [String]
    public var endpointSecrets: [UUID: String]
    public var availableMappingIDs: Set<UUID>

    public init(
        configuration: ModelMoorConfiguration,
        gatewayAPIKeys: [String],
        endpointSecrets: [UUID: String] = [:],
        availableMappingIDs: Set<UUID>? = nil
    ) {
        self.configuration = configuration
        self.gatewayAPIKeys = gatewayAPIKeys
        self.endpointSecrets = endpointSecrets
        self.availableMappingIDs = availableMappingIDs
            ?? Set(configuration.tunnels.flatMap(\.enabledMappings).map(\.id))
    }

    public init(
        configuration: ModelMoorConfiguration,
        gatewayToken: String,
        endpointSecrets: [UUID: String] = [:],
        availableMappingIDs: Set<UUID>? = nil
    ) {
        self.init(
            configuration: configuration,
            gatewayAPIKeys: [gatewayToken],
            endpointSecrets: endpointSecrets,
            availableMappingIDs: availableMappingIDs
        )
    }
}

public struct GatewayRequestRouter: Sendable {
    public static let maximumBodyBytes = 16 * 1_024 * 1_024

    public var snapshot: GatewaySnapshot {
        didSet { rebuildIndexes() }
    }
    private var routesByPublicModel: [String: ModelRouteConfiguration]
    private var endpointsByID: [UUID: APIEndpointConfiguration]
    private var mappingsByID: [UUID: PortMappingConfiguration]

    public init(snapshot: GatewaySnapshot) {
        self.snapshot = snapshot
        self.routesByPublicModel = [:]
        self.endpointsByID = [:]
        self.mappingsByID = [:]
        rebuildIndexes()
    }

    private mutating func rebuildIndexes() {
        var routesByPublicModel: [String: ModelRouteConfiguration] = [:]
        for route in snapshot.configuration.routes where route.enabled {
            routesByPublicModel[route.publicModel] = routesByPublicModel[route.publicModel] ?? route
        }
        self.routesByPublicModel = routesByPublicModel
        var endpointsByID: [UUID: APIEndpointConfiguration] = [:]
        for endpoint in snapshot.configuration.endpoints {
            endpointsByID[endpoint.id] = endpointsByID[endpoint.id] ?? endpoint
        }
        self.endpointsByID = endpointsByID
        var mappingsByID: [UUID: PortMappingConfiguration] = [:]
        for mapping in snapshot.configuration.tunnels.flatMap(\.mappings) {
            mappingsByID[mapping.id] = mappingsByID[mapping.id] ?? mapping
        }
        self.mappingsByID = mappingsByID
    }

    public func route(_ request: GatewayRequest) -> GatewayRouteDecision {
        guard authenticated(request.headers) else {
            return .local(error(status: 401, code: "invalid_api_key", message: "A valid Unified API key is required."))
        }
        let pathAndQuery: (path: String, query: String?)
        do {
            pathAndQuery = try parseURI(request.uri)
        } catch {
            return .local(self.error(status: 400, code: "invalid_request_error", message: error.localizedDescription))
        }

        if request.method == "GET", pathAndQuery.path == "/v1/models" {
            return .local(modelsResponse())
        }
        guard request.method == "POST", pathAndQuery.path.hasPrefix("/v1/") else {
            return .local(error(status: 404, code: "not_found", message: "ModelMoor only exposes GET /v1/models and POST /v1/* routes."))
        }
        guard request.body.count <= Self.maximumBodyBytes else {
            return .local(error(status: 413, code: "request_too_large", message: "Request body exceeds 16 MiB."))
        }
        let contentType = header("content-type", in: request.headers)?.lowercased() ?? ""
        guard contentType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == "application/json" else {
            return .local(error(status: 415, code: "invalid_content_type", message: "Gateway requests must use application/json."))
        }

        let object: NSMutableDictionary
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                throw GatewayRoutingError("Request body must be a JSON object.")
            }
            object = NSMutableDictionary(dictionary: decoded)
        } catch {
            return .local(self.error(status: 400, code: "invalid_json", message: "Request body is not valid JSON."))
        }
        guard let publicModel = object["model"] as? String, !publicModel.isEmpty else {
            return .local(error(status: 400, code: "missing_model", message: "Request body must contain a top-level model string."))
        }
        guard let route = routesByPublicModel[publicModel] else {
            return .local(error(status: 404, code: "model_not_found", message: "No enabled route exists for model \(publicModel)."))
        }
        guard let endpoint = endpointsByID[route.endpointID],
              endpoint.enabled,
              endpoint.kind == .openAICompatible else {
            return .local(error(status: 503, code: "endpoint_unavailable", message: "The selected endpoint is unavailable."))
        }
        if case let .sshMapping(mappingID, _) = endpoint.source,
           !snapshot.availableMappingIDs.contains(mappingID) {
            return .local(error(status: 503, code: "transport_unavailable", message: "The selected SSH transport is not connected."))
        }

        let secret = snapshot.endpointSecrets[endpoint.id]
        if endpoint.authentication != .none, secret?.isEmpty != false {
            return .local(error(status: 424, code: "credential_unavailable", message: "The selected endpoint credential is unavailable."))
        }
        object["model"] = route.upstreamModel
        let rewrittenBody: Data
        do {
            rewrittenBody = try JSONSerialization.data(withJSONObject: object)
        } catch {
            return .local(self.error(status: 400, code: "invalid_json", message: "Request body could not be rewritten."))
        }

        let suffix = String(pathAndQuery.path.dropFirst("/v1".count))
        let upstreamPath = joinedPath(endpoint.basePath, suffix)
        let upstreamURL: URL
        do {
            var components = URLComponents(
                url: try EndpointURLResolver.resolve(endpoint, path: upstreamPath, mappings: mappingsByID),
                resolvingAgainstBaseURL: false
            )
            components?.percentEncodedQuery = pathAndQuery.query
            guard let resolved = components?.url else { throw GatewayRoutingError("Invalid upstream URL.") }
            upstreamURL = resolved
        } catch {
            return .local(self.error(status: 503, code: "endpoint_unavailable", message: error.localizedDescription))
        }

        var upstream = URLRequest(url: upstreamURL)
        upstream.httpMethod = request.method
        upstream.httpBody = rewrittenBody
        let stripped = Set([
            "authorization", "host", "content-length", "connection", "keep-alive",
            "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"
        ])
        for (name, value) in request.headers where !stripped.contains(name.lowercased()) {
            upstream.setValue(value, forHTTPHeaderField: name)
        }
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue(String(rewrittenBody.count), forHTTPHeaderField: "Content-Length")
        upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let secret {
            switch endpoint.authentication {
            case .none: break
            case .bearer: upstream.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            case let .header(name): upstream.setValue(secret, forHTTPHeaderField: name)
            }
        }
        return .upstream(GatewayPreparedRequest(routeID: route.id, endpointID: endpoint.id, urlRequest: upstream))
    }

    private func authenticated(_ headers: [String: String]) -> Bool {
        guard snapshot.configuration.gateway.requiresAPIKey else { return true }
        guard let value = header("authorization", in: headers),
              let separator = value.firstIndex(of: " "),
              value[..<separator].caseInsensitiveCompare("Bearer") == .orderedSame else { return false }
        let candidate = String(value[value.index(after: separator)...])
        var matched = false
        for key in snapshot.gatewayAPIKeys where !key.isEmpty {
            matched = constantTimeEqual(candidate, key) || matched
        }
        return matched
    }

    private func modelsResponse() -> GatewayLocalResponse {
        let models = routesByPublicModel.values
            .map { ["id": $0.publicModel, "object": "model", "owned_by": "modelmoor"] }
            .sorted { ($0["id"] ?? "") < ($1["id"] ?? "") }
        let body = (try? JSONSerialization.data(withJSONObject: ["object": "list", "data": models])) ?? Data("{\"object\":\"list\",\"data\":[]}".utf8)
        return GatewayLocalResponse(status: 200, body: body)
    }

    private func error(status: Int, code: String, message: String) -> GatewayLocalResponse {
        let payload: [String: Any] = ["error": ["message": message, "type": "modelmoor_error", "code": code]]
        return GatewayLocalResponse(
            status: status,
            body: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        )
    }

    private func parseURI(_ uri: String) throws -> (path: String, query: String?) {
        guard let components = URLComponents(string: uri), components.path.hasPrefix("/") else {
            throw GatewayRoutingError("Request URI is invalid.")
        }
        return (components.path, components.percentEncodedQuery)
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func joinedPath(_ base: String, _ suffix: String) -> String {
        let left = base == "/" ? "" : base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let right = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pieces = [left, right].filter { !$0.isEmpty }
        return "/" + pieces.joined(separator: "/")
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: a.count ^ b.count)
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }
}

private struct GatewayRoutingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
