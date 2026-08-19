import Foundation

public enum APIEndpointKind: String, Codable, CaseIterable, Equatable, Sendable {
    case openAICompatible
    case ollama
    case customHTTP

    public var isLLMAPI: Bool {
        switch self {
        case .openAICompatible, .ollama: true
        case .customHTTP: false
        }
    }
}

public enum APIEndpointSource: Codable, Equatable, Sendable {
    case sshMapping(mappingID: UUID, originScheme: EndpointScheme)
    case directHTTPS(originURL: URL)

    private enum CodingKeys: String, CodingKey {
        case type, mappingID, originScheme, originURL
    }

    private enum SourceType: String, Codable {
        case sshMapping, directHTTPS
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(SourceType.self, forKey: .type) {
        case .sshMapping:
            self = .sshMapping(
                mappingID: try container.decode(UUID.self, forKey: .mappingID),
                originScheme: try container.decode(EndpointScheme.self, forKey: .originScheme)
            )
        case .directHTTPS:
            self = .directHTTPS(originURL: try container.decode(URL.self, forKey: .originURL))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .sshMapping(mappingID, originScheme):
            try container.encode(SourceType.sshMapping, forKey: .type)
            try container.encode(mappingID, forKey: .mappingID)
            try container.encode(originScheme, forKey: .originScheme)
        case let .directHTTPS(originURL):
            try container.encode(SourceType.directHTTPS, forKey: .type)
            try container.encode(originURL, forKey: .originURL)
        }
    }
}

public enum APIEndpointAuthentication: Codable, Equatable, Sendable {
    case none
    case bearer
    case header(name: String)

    private enum CodingKeys: String, CodingKey { case type, name }
    private enum AuthenticationType: String, Codable { case none, bearer, header }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(AuthenticationType.self, forKey: .type) {
        case .none: self = .none
        case .bearer: self = .bearer
        case .header: self = .header(name: try container.decode(String.self, forKey: .name))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(AuthenticationType.none, forKey: .type)
        case .bearer:
            try container.encode(AuthenticationType.bearer, forKey: .type)
        case let .header(name):
            try container.encode(AuthenticationType.header, forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }
}

public struct EndpointAPIKeyConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

public struct APIEndpointConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var source: APIEndpointSource
    public var kind: APIEndpointKind
    public var basePath: String
    public var healthPath: String
    public var modelListPath: String?
    public var pollIntervalSeconds: Int
    public var authentication: APIEndpointAuthentication
    public var apiKeys: [EndpointAPIKeyConfiguration]
    public var activeAPIKeyID: UUID?
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        source: APIEndpointSource,
        kind: APIEndpointKind = .openAICompatible,
        basePath: String = "/v1",
        healthPath: String = "/v1/models",
        modelListPath: String? = "/v1/models",
        pollIntervalSeconds: Int = 30,
        authentication: APIEndpointAuthentication = .none,
        apiKeys: [EndpointAPIKeyConfiguration]? = nil,
        activeAPIKeyID: UUID? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.kind = kind
        self.basePath = basePath
        self.healthPath = healthPath
        self.modelListPath = modelListPath
        self.pollIntervalSeconds = pollIntervalSeconds
        self.authentication = authentication
        let resolvedKeys = apiKeys ?? (authentication == .none
            ? []
            : [EndpointAPIKeyConfiguration(id: id, name: "Default key")])
        self.apiKeys = resolvedKeys
        self.activeAPIKeyID = activeAPIKeyID ?? resolvedKeys.first?.id
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, source, kind, basePath, healthPath, modelListPath
        case pollIntervalSeconds, authentication, apiKeys, activeAPIKeyID, enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(APIEndpointSource.self, forKey: .source)
        kind = try container.decode(APIEndpointKind.self, forKey: .kind)
        basePath = try container.decode(String.self, forKey: .basePath)
        healthPath = try container.decode(String.self, forKey: .healthPath)
        modelListPath = try container.decodeIfPresent(String.self, forKey: .modelListPath)
        pollIntervalSeconds = try container.decode(Int.self, forKey: .pollIntervalSeconds)
        authentication = try container.decode(APIEndpointAuthentication.self, forKey: .authentication)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        apiKeys = try container.decodeIfPresent(
            [EndpointAPIKeyConfiguration].self,
            forKey: .apiKeys
        ) ?? (authentication == .none ? [] : [EndpointAPIKeyConfiguration(id: id, name: "Default key")])
        activeAPIKeyID = try container.decodeIfPresent(UUID.self, forKey: .activeAPIKeyID)
            ?? apiKeys.first?.id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(source, forKey: .source)
        try container.encode(kind, forKey: .kind)
        try container.encode(basePath, forKey: .basePath)
        try container.encode(healthPath, forKey: .healthPath)
        try container.encodeIfPresent(modelListPath, forKey: .modelListPath)
        try container.encode(pollIntervalSeconds, forKey: .pollIntervalSeconds)
        try container.encode(authentication, forKey: .authentication)
        try container.encode(apiKeys, forKey: .apiKeys)
        try container.encodeIfPresent(activeAPIKeyID, forKey: .activeAPIKeyID)
        try container.encode(enabled, forKey: .enabled)
    }

    public static func deepSeek(id: UUID = UUID(), name: String = "DeepSeek") -> Self {
        Self(
            id: id,
            name: name,
            source: .directHTTPS(originURL: URL(string: "https://api.deepseek.com")!),
            basePath: "",
            healthPath: "/models",
            modelListPath: "/models",
            authentication: .bearer
        )
    }

    public static func moonshot(
        id: UUID = UUID(),
        name: String = "Moonshot / Kimi Open Platform"
    ) -> Self {
        Self(
            id: id,
            name: name,
            source: .directHTTPS(originURL: URL(string: "https://api.moonshot.cn")!),
            basePath: "/v1",
            healthPath: "/v1/models",
            modelListPath: "/v1/models",
            authentication: .bearer
        )
    }

    public static var recommendedCloudEndpoints: [Self] {
        var endpoints: [Self] = [.moonshot(), .deepSeek()]
        for index in endpoints.indices { endpoints[index].enabled = false }
        return endpoints
    }

    public func validated(mappingIDs: Set<UUID>) throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidValue("Endpoint name cannot be empty.")
        }
        try EndpointURLResolver.validatePath(basePath, field: "Endpoint base path", allowEmpty: true)
        try EndpointURLResolver.validatePath(healthPath, field: "Endpoint health path", allowEmpty: false)
        if let modelListPath {
            try EndpointURLResolver.validatePath(modelListPath, field: "Endpoint model list path", allowEmpty: false)
        }
        guard pollIntervalSeconds == 0 || (10...300).contains(pollIntervalSeconds) else {
            throw ConfigurationError.invalidValue("Endpoint polling interval must be 0 or between 10 and 300 seconds.")
        }
        switch source {
        case let .sshMapping(mappingID, _):
            guard mappingIDs.contains(mappingID) else {
                throw ConfigurationError.invalidValue("Endpoint \(name) refers to a missing SSH mapping.")
            }
        case let .directHTTPS(originURL):
            try EndpointURLResolver.validateDirectOrigin(originURL)
        }
        if case let .header(name) = authentication {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let reserved = Set([
                "authorization", "host", "content-length", "connection", "keep-alive",
                "proxy-authenticate", "proxy-authorization", "te", "trailer",
                "transfer-encoding", "upgrade"
            ])
            guard !trimmed.isEmpty,
                  !reserved.contains(trimmed.lowercased()),
                  trimmed.utf8.allSatisfy({ byte in
                      byte.isASCIIAlphaNumeric || "!#$%&'*+-.^_`|~".utf8.contains(byte)
                  }) else {
                throw ConfigurationError.invalidValue("Custom authentication header name is invalid.")
            }
        }
        guard Set(apiKeys.map(\.id)).count == apiKeys.count else {
            throw ConfigurationError.invalidValue("Endpoint API key identifiers must be unique.")
        }
        var apiKeyNames = Set<String>()
        for key in apiKeys {
            let keyName = key.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyName.isEmpty, keyName.count <= 80 else {
                throw ConfigurationError.invalidValue("Endpoint API key names must contain 1 to 80 characters.")
            }
            guard apiKeyNames.insert(keyName.lowercased()).inserted else {
                throw ConfigurationError.invalidValue("Duplicate Endpoint API key name: \(keyName)")
            }
        }
        if let activeAPIKeyID, !apiKeys.contains(where: { $0.id == activeAPIKeyID }) {
            throw ConfigurationError.invalidValue("The selected Endpoint API key does not exist.")
        }
        return self
    }
}

private extension UInt8 {
    var isASCIIAlphaNumeric: Bool {
        (48...57).contains(self) || (65...90).contains(self) || (97...122).contains(self)
    }
}

public struct ModelRouteConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var publicModel: String
    public var endpointID: UUID
    public var upstreamModel: String
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        publicModel: String,
        endpointID: UUID,
        upstreamModel: String,
        enabled: Bool = true
    ) {
        self.id = id
        self.publicModel = publicModel
        self.endpointID = endpointID
        self.upstreamModel = upstreamModel
        self.enabled = enabled
    }
}

public struct GatewayAPIKeyConfiguration: Codable, Equatable, Identifiable, Sendable {
    public static let defaultKeyID = UUID(uuidString: "6F2E8B9A-92FD-4DE8-9008-5A7BF776ED13")!

    public var id: UUID
    public var name: String
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.enabled = enabled
    }

    public static var defaultKey: Self {
        Self(id: defaultKeyID, name: "Default key")
    }
}

public struct GatewayConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var listenPort: Int
    public var requiresAPIKey: Bool
    public var apiKeys: [GatewayAPIKeyConfiguration]

    public init(
        enabled: Bool = false,
        listenPort: Int = 17_777,
        requiresAPIKey: Bool = true,
        apiKeys: [GatewayAPIKeyConfiguration] = [.defaultKey]
    ) {
        self.enabled = enabled
        self.listenPort = listenPort
        self.requiresAPIKey = requiresAPIKey
        self.apiKeys = apiKeys
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, listenPort, requiresAPIKey, apiKeys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        listenPort = try container.decodeIfPresent(Int.self, forKey: .listenPort) ?? 17_777
        requiresAPIKey = try container.decodeIfPresent(Bool.self, forKey: .requiresAPIKey) ?? true
        apiKeys = try container.decodeIfPresent([GatewayAPIKeyConfiguration].self, forKey: .apiKeys) ?? [.defaultKey]
    }

    public func validated() throws -> Self {
        guard (1_024...65_535).contains(listenPort) else {
            throw ConfigurationError.invalidValue("Gateway port must be between 1024 and 65535.")
        }
        guard Set(apiKeys.map(\.id)).count == apiKeys.count else {
            throw ConfigurationError.invalidValue("Unified API key identifiers must be unique.")
        }
        var names = Set<String>()
        for key in apiKeys {
            let name = key.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80 else {
                throw ConfigurationError.invalidValue("Unified API key names must contain 1 to 80 characters.")
            }
            guard names.insert(name.lowercased()).inserted else {
                throw ConfigurationError.invalidValue("Duplicate Unified API key name: \(name)")
            }
        }
        if requiresAPIKey, !apiKeys.contains(where: \.enabled) {
            throw ConfigurationError.invalidValue("Unified API requires at least one enabled API key.")
        }
        return self
    }
}

public enum EndpointURLResolver {
    public static func resolve(
        _ endpoint: APIEndpointConfiguration,
        path: String? = nil,
        mappings: [UUID: PortMappingConfiguration]
    ) throws -> URL {
        let origin: URL
        switch endpoint.source {
        case let .sshMapping(mappingID, originScheme):
            guard let mapping = mappings[mappingID], mapping.direction == .local else {
                throw ConfigurationError.invalidValue("Endpoint \(endpoint.name) has no reachable local SSH mapping.")
            }
            guard var components = URLComponents() as URLComponents? else {
                throw ConfigurationError.invalidValue("Could not build endpoint URL.")
            }
            components.scheme = originScheme.rawValue
            components.host = mapping.listenHost == "localhost" ? "127.0.0.1" : mapping.listenHost
            components.port = mapping.listenPort
            guard let url = components.url else {
                throw ConfigurationError.invalidValue("Could not build endpoint URL.")
            }
            origin = url
        case let .directHTTPS(originURL):
            try validateDirectOrigin(originURL)
            origin = originURL
        }

        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw ConfigurationError.invalidValue("Could not normalize endpoint URL.")
        }
        components.path = normalizedPath(path ?? endpoint.basePath)
        guard let resolved = components.url else {
            throw ConfigurationError.invalidValue("Could not build endpoint URL.")
        }
        return resolved
    }

    public static func parseDirectBaseURL(_ value: String) throws -> (origin: URL, basePath: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ConfigurationError.invalidValue("Direct endpoint URL is invalid.")
        }
        guard components.query == nil, components.fragment == nil else {
            throw ConfigurationError.invalidValue("Direct endpoint URL cannot contain a query or fragment.")
        }
        let basePath = normalizedPath(components.path)
        components.path = ""
        guard let origin = components.url else {
            throw ConfigurationError.invalidValue("Direct endpoint origin is invalid.")
        }
        try validateDirectOrigin(origin)
        return (origin, basePath)
    }

    static func validateDirectOrigin(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil else {
            throw ConfigurationError.invalidValue("Direct endpoint origin must be an HTTPS origin without credentials, path, query, or fragment.")
        }
    }

    static func validatePath(_ value: String, field: String, allowEmpty: Bool) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowEmpty || !trimmed.isEmpty else {
            throw ConfigurationError.invalidValue("\(field) cannot be empty.")
        }
        guard trimmed.isEmpty || trimmed.hasPrefix("/") else {
            throw ConfigurationError.invalidValue("\(field) must be an absolute path.")
        }
        guard !trimmed.contains("?"), !trimmed.contains("#"), !trimmed.contains(where: \ .isNewline) else {
            throw ConfigurationError.invalidValue("\(field) cannot contain a query, fragment, or newline.")
        }
    }

    static func normalizedPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return trimmed == "/" ? "/" : "" }
        let prefixed = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        return prefixed.count > 1 && prefixed.hasSuffix("/") ? String(prefixed.dropLast()) : prefixed
    }
}
